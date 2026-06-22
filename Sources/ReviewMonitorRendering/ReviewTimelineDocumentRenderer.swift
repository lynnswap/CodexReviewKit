import Foundation
import CodexReviewDomain

public struct ReviewTimelineDocumentRenderer: Sendable {
    public init() {}

    @MainActor
    public func document(from timeline: ReviewTimeline) -> ReviewTimelineDocument {
        let activeBlockIDs = timeline.orderedItemIDs
            .filter { timeline.activeItemIDs.contains($0) }
            .map(ReviewTimelineDocument.Block.ID.init(itemID:))
        let blocks = timeline.items.map { item in
            Self.block(for: item, isActive: timeline.activeItemIDs.contains(item.id))
        }
        return ReviewTimelineDocument(
            timelineRevision: timeline.revision,
            orderedBlockIDs: blocks.map(\.id),
            activeBlockIDs: activeBlockIDs,
            activeBlockCount: activeBlockIDs.count,
            latestActivityBlockID: timeline.latestActivity.map(ReviewTimelineDocument.Block.ID.init(itemID:)),
            terminalStatus: timeline.terminalStatus,
            terminalSummary: timeline.terminalSummary,
            terminalResult: timeline.terminalResult,
            blocks: blocks
        )
    }

    @MainActor
    public func plainText(from timeline: ReviewTimeline) -> String {
        document(from: timeline).plainText
    }

    @MainActor
    private static func block(for item: ReviewTimelineItem, isActive: Bool) -> ReviewTimelineDocument.Block {
        let content = Self.content(for: item.content)
        return ReviewTimelineDocument.Block(
            id: .init(itemID: item.id),
            sourceItemID: item.id,
            kind: item.kind,
            family: item.family,
            phase: item.phase,
            isActive: isActive,
            primaryText: Self.primaryText(for: content),
            rawTranscriptText: Self.rawTranscriptText(for: content),
            content: content,
            createdAt: item.createdAt,
            updatedAt: item.updatedAt,
            startedAt: item.startedAt,
            completedAt: item.completedAt,
            durationMs: item.durationMs
        )
    }

    private static func content(for content: ReviewTimelineItem.Content) -> ReviewTimelineDocument.Content {
        switch content {
        case .approval(let approval):
            return .approval(.init(
                title: approval.title,
                detail: approval.detail,
                decision: approval.decision,
                scope: approval.scope,
                risk: approval.risk,
                status: approval.status
            ))
        case .command(let command):
            return .command(.init(
                title: command.command,
                command: command.command,
                cwd: command.cwd,
                output: command.output,
                exitCode: command.exitCode,
                status: command.status,
                source: command.source,
                processID: command.processID,
                actions: command.actions.map {
                    .init(
                        kind: $0.kind,
                        command: $0.command,
                        name: $0.name,
                        path: $0.path,
                        query: $0.query
                    )
                },
                durationMs: command.durationMs
            ))
        case .contextCompaction(let contextCompaction):
            return .contextCompaction(.init(
                title: contextCompaction.title,
                status: contextCompaction.status,
                inputTokens: contextCompaction.inputTokens,
                outputTokens: contextCompaction.outputTokens
            ))
        case .diagnostic(let diagnostic):
            return .diagnostic(.init(
                message: diagnostic.message,
                severity: diagnostic.severity,
                retry: diagnostic.retry.map {
                    .init(
                        state: $0.state,
                        attempt: $0.attempt,
                        maxAttempts: $0.maxAttempts,
                        delayMs: $0.delayMs
                    )
                }
            ))
        case .fileChange(let fileChange):
            return .fileChange(.init(
                title: fileChange.title,
                output: fileChange.output,
                paths: fileChange.paths,
                patch: fileChange.patch,
                status: fileChange.status
            ))
        case .message(let message):
            return .message(.init(text: message.text))
        case .plan(let plan):
            return .plan(.init(markdown: plan.markdown))
        case .reasoning(let reasoning):
            return .reasoning(.init(text: reasoning.text, style: reasoning.style))
        case .search(let search):
            return .search(.init(
                query: search.query,
                result: search.result,
                status: search.status,
                resultCount: search.resultCount,
                durationMs: search.durationMs
            ))
        case .toolCall(let toolCall):
            return .toolCall(.init(
                namespace: toolCall.namespace,
                server: toolCall.server,
                name: toolCall.tool,
                arguments: toolCall.arguments,
                result: toolCall.result,
                error: toolCall.error,
                status: toolCall.status,
                durationMs: toolCall.durationMs,
                appContext: toolCall.appContext,
                pluginID: toolCall.pluginID,
                callID: toolCall.callID,
                progress: toolCall.progress
            ))
        case .unknown(let unknown):
            return .unknown(.init(
                title: unknown.title,
                detail: unknown.detail,
                rawKind: unknown.rawKind,
                rawStatus: unknown.rawStatus,
                references: unknown.references.map {
                    .init(kind: $0.kind, value: $0.value, label: $0.label)
                }
            ))
        }
    }

    private static func primaryText(for content: ReviewTimelineDocument.Content) -> String {
        switch content {
        case .approval(let approval):
            return approval.title
        case .command(let command):
            return command.title
        case .contextCompaction(let contextCompaction):
            return contextCompaction.title
        case .diagnostic(let diagnostic):
            return diagnostic.message
        case .fileChange(let fileChange):
            return fileChange.title
        case .message(let message):
            return message.text
        case .plan(let plan):
            return plan.markdown
        case .reasoning(let reasoning):
            return reasoning.text
        case .search(let search):
            return search.query
        case .toolCall(let toolCall):
            return [toolCall.namespace, toolCall.server, toolCall.name].compactMap { $0 }.joined(separator: ".")
        case .unknown(let unknown):
            return unknown.title
        }
    }

    private static func rawTranscriptText(for content: ReviewTimelineDocument.Content) -> String {
        switch content {
        case .approval(let approval):
            return [approval.title, approval.detail].compactMap { $0 }.joined(separator: "\n")
        case .command(let command):
            return command.output.isEmpty ? "$ \(command.command)" : "$ \(command.command)\n\(command.output)"
        case .contextCompaction(let contextCompaction):
            return contextCompaction.title
        case .diagnostic(let diagnostic):
            return diagnostic.message
        case .fileChange(let fileChange):
            return fileChange.output.isEmpty ? fileChange.title : "\(fileChange.title)\n\(fileChange.output)"
        case .message(let message):
            return message.text
        case .plan(let plan):
            return plan.markdown
        case .reasoning(let reasoning):
            return reasoning.text
        case .search(let search):
            return [search.query, search.result].compactMap { $0 }.joined(separator: "\n")
        case .toolCall(let toolCall):
            return [toolCall.namespace, toolCall.server, toolCall.name].compactMap { $0 }.joined(separator: ".")
        case .unknown(let unknown):
            return [unknown.title, unknown.detail].compactMap { $0 }.joined(separator: "\n")
        }
    }
}
