import Foundation
import CodexReviewDomain

public struct ReviewTimelineDocumentRenderer: Sendable {
    public init() {}

    @MainActor
    public func plainText(from timeline: ReviewTimeline) -> String {
        timeline.items.map(Self.text(for:)).filter { $0.isEmpty == false }.joined(separator: "\n\n")
    }

    @MainActor
    private static func text(for item: ReviewTimelineItem) -> String {
        switch item.content {
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
            return [toolCall.namespace, toolCall.server, toolCall.tool].compactMap { $0 }.joined(separator: ".")
        case .unknown(let unknown):
            return [unknown.title, unknown.detail].compactMap { $0 }.joined(separator: "\n")
        }
    }
}
