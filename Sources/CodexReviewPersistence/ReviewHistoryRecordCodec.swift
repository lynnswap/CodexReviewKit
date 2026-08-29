import CodexReview
import Foundation

struct EncodedReviewHistoryRecord {
    var workspace: ReviewWorkspaceRow
    var review: ReviewRecordRow
    var findings: [ReviewFindingRow]
}

enum ReviewHistoryRecordCodec {
    static func encodeStarted(
        _ record: ReviewHistoryRecord,
        createdAt: Date,
        updatedAt: Date
    ) throws -> EncodedReviewHistoryRecord {
        try validateCommon(record)
        guard record.isTerminal == false,
              record.core.lifecycle.status == .queued || record.core.lifecycle.status == .running,
              record.core.lifecycle.terminal == nil,
              record.core.lifecycle.endedAt == nil,
              record.core.lifecycle.cancellation == nil,
              record.core.output.hasFinalReview == false,
              record.core.output.lastAgentMessage == nil,
              record.core.output.reviewResult == nil
        else {
            throw invalid(record, "started records must contain only nonterminal semantic state")
        }

        return try encode(
            record,
            createdAt: createdAt,
            updatedAt: updatedAt,
            parsedResult: nil
        )
    }

    static func encodeTerminal(
        _ record: ReviewHistoryRecord,
        createdAt: Date,
        updatedAt: Date
    ) throws -> EncodedReviewHistoryRecord {
        try validateCommon(record)
        guard record.isTerminal, let terminal = record.core.lifecycle.terminal else {
            throw invalid(record, "terminal records require a typed terminal")
        }

        let lifecycle = record.core.lifecycle
        let output = record.core.output
        if let startedAt = lifecycle.startedAt,
           let endedAt = lifecycle.endedAt,
           endedAt < startedAt {
            throw invalid(record, "endedAt precedes startedAt")
        }

        switch terminal {
        case .completed:
            guard lifecycle.status == .succeeded,
                  lifecycle.endedAt != nil,
                  lifecycle.cancellation == nil,
                  output.hasFinalReview,
                  let finalReview = output.lastAgentMessage,
                  finalReview == finalReview.trimmingCharacters(in: .whitespacesAndNewlines),
                  finalReview.isEmpty == false,
                  finalReview.utf8.count <= ReviewFinalResult.maximumUTF8Bytes,
                  let parsedResult = output.reviewResult
            else {
                throw invalid(
                    record,
                    "completed records require a bounded canonical final review and parsed result"
                )
            }
            try validate(parsedResult, record: record)
        case .interrupted(.requested(let cancellation)):
            guard lifecycle.status == .cancelled,
                  lifecycle.endedAt != nil,
                  lifecycle.cancellation == cancellation
            else {
                throw invalid(record, "requested interruption does not match cancellation state")
            }
            try validateNoFinalProjection(record)
        case .interrupted(.server):
            guard lifecycle.status == .failed,
                  lifecycle.endedAt != nil,
                  lifecycle.cancellation == nil
            else {
                throw invalid(record, "server interruption does not match failed lifecycle state")
            }
            try validateNoFinalProjection(record)
        case .interrupted(.transport(let message)):
            guard lifecycle.status == .failed,
                  lifecycle.endedAt != nil,
                  lifecycle.cancellation == nil,
                  message.nilIfEmpty != nil
            else {
                throw invalid(record, "transport interruption requires a message and failed state")
            }
            try validateNoFinalProjection(record)
        case .interrupted(.previousProcessExit):
            guard lifecycle.status == .failed,
                  lifecycle.endedAt == nil,
                  lifecycle.cancellation == nil
            else {
                throw invalid(record, "previous-process interruption must keep endedAt unknown")
            }
            try validateNoFinalProjection(record)
        case .failed:
            guard lifecycle.status == .failed,
                  lifecycle.endedAt != nil,
                  lifecycle.cancellation == nil
            else {
                throw invalid(record, "failed terminal does not match lifecycle state")
            }
            try validateNoFinalProjection(record)
        }

        return try encode(
            record,
            createdAt: createdAt,
            updatedAt: updatedAt,
            parsedResult: output.reviewResult
        )
    }

    static func decode(
        _ row: ReviewRecordRow,
        workspace: ReviewWorkspaceRow,
        findings: [ReviewFindingRow]
    ) throws -> ReviewHistoryRecord {
        guard row.cwd == workspace.cwd else {
            throw invalid(row.id, "workspace foreign key does not match loaded workspace")
        }
        let target = try decodeTarget(row)
        guard let status = ReviewJobState(rawValue: row.status) else {
            throw invalid(row.id, "unknown lifecycle status \(row.status)")
        }
        let terminal = try decodeTerminal(row, status: status)
        let parsedResult = try decodeParsedResult(row, findings: findings)
        let cancellation: ReviewCancellation? = switch terminal {
        case .interrupted(.requested(let cancellation)):
            cancellation
        case .completed, .interrupted, .failed, nil:
            nil
        }

        let record = ReviewHistoryRecord(
            id: row.id,
            cwd: row.cwd,
            workspaceSortOrder: workspace.sortOrder,
            sortOrder: row.sortOrder,
            target: target,
            core: ReviewJobCore(
                run: .init(
                    reviewThreadID: row.reviewThreadID,
                    threadID: row.threadID,
                    turnID: row.turnID,
                    model: row.model
                ),
                lifecycle: .init(
                    status: status,
                    exitCode: row.exitCode,
                    startedAt: row.startedAt,
                    endedAt: row.endedAt,
                    cancellation: cancellation,
                    errorMessage: row.errorMessage,
                    terminal: terminal
                ),
                output: .init(
                    summary: row.summary,
                    hasFinalReview: row.hasFinalReview,
                    lastAgentMessage: row.canonicalFinalReview,
                    reviewResult: parsedResult
                )
            )
        )

        let reencoded: EncodedReviewHistoryRecord
        if record.isTerminal {
            reencoded = try encodeTerminal(
                record,
                createdAt: row.createdAt,
                updatedAt: row.updatedAt
            )
        } else {
            reencoded = try encodeStarted(
                record,
                createdAt: row.createdAt,
                updatedAt: row.updatedAt
            )
        }
        guard reencoded.workspace == workspace,
              reencoded.review == row,
              reencoded.findings.sorted(by: { $0.ordinal < $1.ordinal })
                == findings.sorted(by: { $0.ordinal < $1.ordinal })
        else {
            throw invalid(row.id, "storage columns do not match the decoded semantic record")
        }
        return record
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
        do {
            guard try target.validated() == target else {
                throw invalid(row.id, "target payload is not canonical")
            }
        } catch let error as ReviewHistoryDatabaseError {
            throw error
        } catch {
            throw invalid(row.id, "target payload failed validation: \(error.localizedDescription)")
        }
        return target
    }

    private static func encode(
        _ record: ReviewHistoryRecord,
        createdAt: Date,
        updatedAt: Date,
        parsedResult: ParsedReviewResult?
    ) throws -> EncodedReviewHistoryRecord {
        guard let startedAt = record.core.lifecycle.startedAt else {
            throw invalid(record, "startedAt is required")
        }
        let targetColumns = targetColumns(record.target)
        let terminalColumns = terminalColumns(record.core.lifecycle.terminal)
        let findingRows = try parsedResult?.findings.enumerated().map { ordinal, finding in
            try encode(finding, reviewID: record.id, ordinal: ordinal, record: record)
        } ?? []

        return EncodedReviewHistoryRecord(
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
                reviewThreadID: record.core.run.reviewThreadID,
                threadID: record.core.run.threadID,
                turnID: record.core.run.turnID,
                model: record.core.run.model,
                status: record.core.lifecycle.status.rawValue,
                exitCode: record.core.lifecycle.exitCode,
                startedAt: startedAt,
                endedAt: record.core.lifecycle.endedAt,
                cancellationSource: terminalColumns.cancellation?.source.rawValue,
                cancellationMessage: terminalColumns.cancellation?.message,
                terminalKind: terminalColumns.kind,
                interruptionKind: terminalColumns.interruptionKind,
                terminalMessage: terminalColumns.message,
                errorMessage: record.core.lifecycle.errorMessage,
                summary: record.core.output.summary,
                hasFinalReview: record.core.output.hasFinalReview,
                canonicalFinalReview: record.core.output.lastAgentMessage,
                parsedState: parsedResult?.state.rawValue,
                parsedFindingCount: parsedResult?.findingCount,
                parsedSource: parsedResult?.source.rawValue,
                parserVersion: parsedResult?.parserVersion,
                createdAt: createdAt,
                updatedAt: updatedAt
            ),
            findings: findingRows
        )
    }

    private static func validateCommon(_ record: ReviewHistoryRecord) throws {
        guard record.id.nilIfEmpty != nil else {
            throw invalid(record, "review ID is empty")
        }
        guard record.cwd.nilIfEmpty != nil else {
            throw invalid(record, "workspace path is empty")
        }
        guard record.workspaceSortOrder.isFinite, record.sortOrder.isFinite else {
            throw invalid(record, "sort order must be finite")
        }
        guard record.core.lifecycle.startedAt != nil else {
            throw invalid(record, "startedAt is required")
        }
        do {
            guard try record.target.validated() == record.target else {
                throw invalid(record, "target payload is not canonical")
            }
        } catch let error as ReviewHistoryDatabaseError {
            throw error
        } catch {
            throw invalid(record, "target payload failed validation: \(error.localizedDescription)")
        }
    }

    private static func validateNoFinalProjection(_ record: ReviewHistoryRecord) throws {
        guard record.core.output.hasFinalReview == false,
              record.core.output.lastAgentMessage == nil,
              record.core.output.reviewResult == nil
        else {
            throw invalid(
                record,
                "non-completed records cannot contain a partial final-review projection"
            )
        }
    }

    private static func validate(
        _ parsedResult: ParsedReviewResult,
        record: ReviewHistoryRecord
    ) throws {
        guard parsedResult.parserVersion > 0 else {
            throw invalid(record, "parser version must be positive")
        }
        switch (parsedResult.state, parsedResult.source) {
        case (.hasFindings, .parsedFinalReviewText):
            guard parsedResult.findings.isEmpty == false,
                  parsedResult.findingCount == parsedResult.findings.count
            else {
                throw invalid(record, "finding projection count is inconsistent")
            }
        case (.noFindings, .parsedFinalReviewText):
            guard parsedResult.findings.isEmpty, parsedResult.findingCount == 0 else {
                throw invalid(record, "no-findings projection contains findings")
            }
        case (.unknown, .unrecognizedFindingBlock), (.unknown, .notAvailable):
            guard parsedResult.findings.isEmpty, parsedResult.findingCount == nil else {
                throw invalid(record, "unknown parsed projection contains findings")
            }
        default:
            throw invalid(record, "parsed state and source are incompatible")
        }
    }

    private static func encode(
        _ finding: ParsedReviewResult.Finding,
        reviewID: String,
        ordinal: Int,
        record: ReviewHistoryRecord
    ) throws -> ReviewFindingRow {
        guard finding.title.nilIfEmpty != nil else {
            throw invalid(record, "finding \(ordinal) has an empty title")
        }
        if let priority = finding.priority, (0...3).contains(priority) == false {
            throw invalid(record, "finding \(ordinal) has an invalid priority")
        }
        if let location = finding.location {
            guard location.path.nilIfEmpty != nil,
                  location.startLine > 0,
                  location.endLine >= location.startLine
            else {
                throw invalid(record, "finding \(ordinal) has an invalid location")
            }
        }
        return ReviewFindingRow(
            id: stableFindingID(reviewID: reviewID, ordinal: ordinal),
            reviewID: reviewID,
            ordinal: ordinal,
            priority: finding.priority,
            title: finding.title,
            body: finding.body,
            path: finding.location?.path,
            startLine: finding.location?.startLine,
            endLine: finding.location?.endLine
        )
    }

    private static func decodeTerminal(
        _ row: ReviewRecordRow,
        status: ReviewJobState
    ) throws -> ReviewTerminalRecord? {
        guard let terminalKind = row.terminalKind else {
            guard status == .queued || status == .running else {
                throw invalid(row.id, "terminal lifecycle is missing a typed terminal")
            }
            return nil
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
    ) throws -> ParsedReviewResult? {
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
        for (expectedOrdinal, finding) in orderedFindings.enumerated() {
            guard finding.reviewID == row.id,
                  finding.ordinal == expectedOrdinal,
                  finding.id == stableFindingID(reviewID: row.id, ordinal: expectedOrdinal)
            else {
                throw invalid(row.id, "finding ordinals or stable identities are inconsistent")
            }
        }
        let decodedFindings = orderedFindings.map { finding in
            let location: ParsedReviewResult.Finding.Location?
            if let path = finding.path,
               let startLine = finding.startLine,
               let endLine = finding.endLine {
                location = .init(path: path, startLine: startLine, endLine: endLine)
            } else {
                location = nil
            }
            return ParsedReviewResult.Finding(
                title: finding.title,
                body: finding.body,
                priority: finding.priority,
                location: location,
                rawText: renderRawFinding(
                    title: finding.title,
                    body: finding.body,
                    location: location
                )
            )
        }
        return ParsedReviewResult(
            state: state,
            findingCount: row.parsedFindingCount,
            findings: decodedFindings,
            source: source,
            parserVersion: parserVersion
        )
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
        _ terminal: ReviewTerminalRecord?
    ) -> (kind: String?, interruptionKind: String?, message: String?, cancellation: ReviewCancellation?) {
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
        case nil:
            (nil, nil, nil, nil)
        }
    }

    private static func stableFindingID(reviewID: String, ordinal: Int) -> String {
        "\(reviewID.utf8.count):\(reviewID):\(ordinal)"
    }

    private static func renderRawFinding(
        title: String,
        body: String,
        location: ParsedReviewResult.Finding.Location?
    ) -> String {
        let locationSuffix = location.map { " \u{2014} \($0.path):\($0.startLine)-\($0.endLine)" } ?? ""
        let firstLine = "- \(title)\(locationSuffix)"
        guard body.isEmpty == false else {
            return firstLine
        }
        return ([firstLine] + body.components(separatedBy: .newlines).map { "  \($0)" })
            .joined(separator: "\n")
    }

    private static func invalid(
        _ record: ReviewHistoryRecord,
        _ reason: String
    ) -> ReviewHistoryDatabaseError {
        invalid(record.id, reason)
    }

    private static func invalid(
        _ id: String,
        _ reason: String
    ) -> ReviewHistoryDatabaseError {
        .invalidRecord(id: id, reason: reason)
    }
}
