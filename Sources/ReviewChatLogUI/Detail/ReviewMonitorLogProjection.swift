import Foundation

package enum ReviewMonitorLog {}

package extension ReviewMonitorLog {
    struct BlockID: Codable, Hashable, Sendable {
        var rawValue: String

        init(_ rawValue: String) {
            self.rawValue = rawValue
        }
    }

    enum Kind: String, Codable, Sendable, Hashable {
        case agentMessage
        case command
        case commandOutput
        case plan
        case todoList
        case reasoning
        case reasoningSummary
        case rawReasoning
        case toolCall
        case diagnostic
        case error
        case progress
        case event
        case contextCompaction
    }

    struct Metadata: Codable, Sendable, Hashable {
        struct CommandAction: Codable, Sendable, Hashable {
            enum Kind: String, Codable, Sendable, Hashable {
                case read
                case listFiles
                case search
                case unknown
            }

            let kind: Kind
            let command: String?
            let name: String?
            let path: String?
            let query: String?

            init(
                kind: Kind,
                command: String? = nil,
                name: String? = nil,
                path: String? = nil,
                query: String? = nil
            ) {
                self.kind = kind
                self.command = command
                self.name = name
                self.path = path
                self.query = query
            }
        }

        let sourceType: String
        let title: String?
        let status: String?
        let detail: String?
        let itemID: String?
        let command: String?
        let cwd: String?
        let exitCode: Int?
        let startedAt: Date?
        let completedAt: Date?
        let durationMs: Int?
        let commandActions: [CommandAction]?
        let commandStatus: String?
        let namespace: String?
        let server: String?
        let tool: String?
        let query: String?
        let path: String?
        let resultText: String?
        let errorText: String?

        init(
            sourceType: String,
            title: String? = nil,
            status: String? = nil,
            detail: String? = nil,
            itemID: String? = nil,
            command: String? = nil,
            cwd: String? = nil,
            exitCode: Int? = nil,
            startedAt: Date? = nil,
            completedAt: Date? = nil,
            durationMs: Int? = nil,
            commandActions: [CommandAction]? = nil,
            commandStatus: String? = nil,
            namespace: String? = nil,
            server: String? = nil,
            tool: String? = nil,
            query: String? = nil,
            path: String? = nil,
            resultText: String? = nil,
            errorText: String? = nil
        ) {
            self.sourceType = sourceType
            self.title = title
            self.status = status
            self.detail = detail
            self.itemID = itemID
            self.command = command
            self.cwd = cwd
            self.exitCode = exitCode
            self.startedAt = startedAt
            self.completedAt = completedAt
            self.durationMs = durationMs
            self.commandActions = commandActions
            self.commandStatus = commandStatus
            self.namespace = namespace
            self.server = server
            self.tool = tool
            self.query = query
            self.path = path
            self.resultText = resultText
            self.errorText = errorText
        }
    }

    struct Block: Equatable, Sendable {
        var id: ReviewMonitorLog.BlockID
        var kind: ReviewMonitorLog.Kind
        var groupID: String?
        var range: NSRange
        var sourceRange: NSRange
        var metadata: ReviewMonitorLog.Metadata?

        init(
            id: ReviewMonitorLog.BlockID,
            kind: ReviewMonitorLog.Kind,
            groupID: String?,
            range: NSRange,
            sourceRange: NSRange? = nil,
            metadata: ReviewMonitorLog.Metadata? = nil
        ) {
            self.id = id
            self.kind = kind
            self.groupID = groupID
            self.range = range
            self.sourceRange = sourceRange ?? range
            self.metadata = metadata
        }
    }

    enum StatusTone: Hashable, Sendable {
        case neutral
        case running
        case success
        case warning
        case failure
    }

    enum PlanStatus: String, Hashable, Sendable {
        case pending
        case inProgress
        case completed
        case failed
    }

    enum TextStyle: Hashable, Sendable {
        case body
        case heading(level: Int)
        case bullet
        case blockquote
        case strong
        case emphasis
        case link
        case strikethrough
        case inlineCode
        case codeFence
        case markdownSyntax
        case command
        case terminalOutput
        case commandOutputControl(keepsTrailingContent: Bool)
        case plan(status: ReviewMonitorLog.PlanStatus?)
        case tool
        case diagnostic
        case error
        case event
        case contextCompaction
        case muted
    }

    struct TextRun: Equatable, Sendable {
        var range: NSRange
        var style: ReviewMonitorLog.TextStyle
    }

    struct AnimationSpan: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case wordFade
        }

        var kind: Kind
        var range: NSRange
    }

    enum DecorationStyle: Hashable, Sendable {
        case transcript
        case command(tone: ReviewMonitorLog.StatusTone)
        case terminal(tone: ReviewMonitorLog.StatusTone)
        case codeBlock
        case plan(tone: ReviewMonitorLog.StatusTone)
        case reasoning
        case tool(tone: ReviewMonitorLog.StatusTone)
        case diagnostic(tone: ReviewMonitorLog.StatusTone)
        case error
        case event
        case contextCompaction(label: String, isCompleted: Bool)
    }

    struct Decoration: Equatable, Sendable {
        var blockID: ReviewMonitorLog.BlockID
        var range: NSRange
        var style: ReviewMonitorLog.DecorationStyle
    }

    struct CommandOutputPanel: Equatable, Sendable {
        var blockID: ReviewMonitorLog.BlockID
        var range: NSRange
        var commandText: String
        var outputText: String
        var outputSourceRange: NSRange? = nil
        var lineCount: Int
        var isExpanded: Bool
        var isActive: Bool
        var startedAt: Date?
        var title: String
        var exitText: String?
    }

    struct Append: Equatable, Sendable {
        var kind: ReviewMonitorLog.Kind
        var blockID: ReviewMonitorLog.BlockID
        var range: NSRange
        var text: String
        var textUTF16Length: Int
        var animationSpans: [ReviewMonitorLog.AnimationSpan]

        init(
            kind: ReviewMonitorLog.Kind,
            blockID: ReviewMonitorLog.BlockID,
            range: NSRange,
            text: String,
            textUTF16Length: Int? = nil,
            animationSpans: [ReviewMonitorLog.AnimationSpan] = []
        ) {
            self.kind = kind
            self.blockID = blockID
            self.range = range
            self.text = text
            self.textUTF16Length = textUTF16Length ?? Self.utf16Length(text)
            self.animationSpans = animationSpans
        }

        private static func utf16Length(_ text: String) -> Int {
            (text as NSString).length
        }

        static func animationSpans(
            forKind kind: ReviewMonitorLog.Kind,
            absoluteRange: NSRange,
            appendBaseLocation: Int
        ) -> [ReviewMonitorLog.AnimationSpan] {
            guard Self.wordFadeKinds.contains(kind),
                absoluteRange.length > 0,
                absoluteRange.location >= appendBaseLocation
            else {
                return []
            }
            return [
                .init(
                    kind: .wordFade,
                    range: NSRange(
                        location: absoluteRange.location - appendBaseLocation,
                        length: absoluteRange.length
                    )
                )
            ]
        }

        private static let wordFadeKinds: Set<ReviewMonitorLog.Kind> = [
            .reasoning,
            .reasoningSummary,
            .rawReasoning,
        ]
    }

    struct Replacement: Equatable, Sendable {
        var kind: ReviewMonitorLog.Kind
        var blockID: ReviewMonitorLog.BlockID
        var range: NSRange
        var text: String
        var textUTF16Length: Int

        init(
            kind: ReviewMonitorLog.Kind,
            blockID: ReviewMonitorLog.BlockID,
            range: NSRange,
            text: String,
            textUTF16Length: Int? = nil
        ) {
            self.kind = kind
            self.blockID = blockID
            self.range = range
            self.text = text
            self.textUTF16Length = textUTF16Length ?? Self.utf16Length(text)
        }

        private static func utf16Length(_ text: String) -> Int {
            (text as NSString).length
        }
    }

    enum Change: Equatable, Sendable {
        case reload
        case append(ReviewMonitorLog.Append)
        case replace(ReviewMonitorLog.Replacement)
    }

    struct Document: Equatable, Sendable {
        var text: String
        var textUTF16Length: Int
        var sourceText: String
        var sourceTextUTF16Length: Int
        var blocks: [ReviewMonitorLog.Block]
        var styleRuns: [ReviewMonitorLog.TextRun]
        var decorations: [ReviewMonitorLog.Decoration]
        var commandOutputPanels: [ReviewMonitorLog.CommandOutputPanel]
        var revision: UInt64
        var lastChange: ReviewMonitorLog.Change

        init(
            text: String = "",
            textUTF16Length: Int? = nil,
            sourceText: String? = nil,
            sourceTextUTF16Length: Int? = nil,
            blocks: [ReviewMonitorLog.Block] = [],
            styleRuns: [ReviewMonitorLog.TextRun] = [],
            decorations: [ReviewMonitorLog.Decoration] = [],
            commandOutputPanels: [ReviewMonitorLog.CommandOutputPanel] = [],
            revision: UInt64 = 0,
            lastChange: ReviewMonitorLog.Change = .reload
        ) {
            self.text = text
            self.textUTF16Length = textUTF16Length ?? Self.utf16Length(text)
            self.sourceText = sourceText ?? text
            self.sourceTextUTF16Length = sourceTextUTF16Length ?? Self.utf16Length(sourceText ?? text)
            self.blocks = blocks
            self.styleRuns = styleRuns
            self.decorations = decorations
            self.commandOutputPanels = commandOutputPanels
            self.revision = revision
            self.lastChange = lastChange
        }

        private static func utf16Length(_ text: String) -> Int {
            (text as NSString).length
        }

        mutating func rebuildPresentation() {
            styleRuns.removeAll(keepingCapacity: true)
            decorations.removeAll(keepingCapacity: true)
            commandOutputPanels.removeAll(keepingCapacity: true)
            for block in blocks {
                ReviewMonitorLogStyler.appendPresentation(for: block, to: &self)
            }
        }

        mutating func rebuildPresentation(forBlockAt blockIndex: Int) {
            guard blocks.indices.contains(blockIndex) else {
                rebuildPresentation()
                return
            }

            let block = blocks[blockIndex]
            styleRuns.removeAll {
                NSIntersectionRange($0.range, block.range).length > 0
            }
            decorations.removeAll {
                $0.blockID == block.id || NSIntersectionRange($0.range, block.range).length > 0
            }
            commandOutputPanels.removeAll {
                $0.blockID == block.id || NSIntersectionRange($0.range, block.range).length > 0
            }
            ReviewMonitorLogStyler.appendPresentation(for: block, to: &self)
        }

        var finderSupplementSignature: Int {
            0
        }
    }
}

enum ReviewMonitorLogStyler {
    struct Presentation {
        var text: String
        var styleRuns: [ReviewMonitorLog.TextRun] = []
        var decorations: [ReviewMonitorLog.Decoration] = []
    }

    static func renderedText(
        for kind: ReviewMonitorLog.Kind,
        source: String,
        blockID: ReviewMonitorLog.BlockID
    ) -> String {
        presentation(for: kind, source: source, blockID: blockID).text
    }

    static func appendPresentation(for block: ReviewMonitorLog.Block, to document: inout ReviewMonitorLog.Document) {
        guard block.range.location >= 0,
            block.range.length >= 0,
            NSMaxRange(block.range) <= document.textUTF16Length,
            block.sourceRange.location >= 0,
            block.sourceRange.length >= 0,
            NSMaxRange(block.sourceRange) <= document.sourceTextUTF16Length
        else {
            return
        }

        let source = (document.sourceText as NSString).substring(with: block.sourceRange)
        let presentation = presentation(for: block.kind, source: source, blockID: block.id)
        if block.range.length > 0 {
            document.styleRuns.append(.init(range: block.range, style: baseTextStyle(for: block.kind)))
            document.decorations.append(
                .init(
                    blockID: block.id,
                    range: block.range,
                    style: decorationStyle(
                        for: block.kind,
                        source: source,
                        metadata: block.metadata
                    )
                ))
        }

        for run in presentation.styleRuns {
            let range = offset(run.range, by: block.range.location, limitingTo: block.range.length)
            guard range.length > 0 else {
                continue
            }
            document.styleRuns.append(.init(range: range, style: run.style))
        }
        for decoration in presentation.decorations {
            let range = offset(decoration.range, by: block.range.location, limitingTo: block.range.length)
            guard range.length > 0 else {
                continue
            }
            document.decorations.append(
                .init(
                    blockID: decoration.blockID,
                    range: range,
                    style: decoration.style
                ))
        }
    }

    private static func presentation(
        for kind: ReviewMonitorLog.Kind,
        source: String,
        blockID: ReviewMonitorLog.BlockID
    ) -> Presentation {
        switch kind {
        case .agentMessage, .reasoning, .reasoningSummary, .rawReasoning:
            return renderMarkdown(source, blockID: blockID)
        case .plan, .todoList:
            return renderPlan(source)
        case .command, .commandOutput, .toolCall, .diagnostic, .error, .progress, .event, .contextCompaction:
            return .init(text: source)
        }
    }

    private static func baseTextStyle(for kind: ReviewMonitorLog.Kind) -> ReviewMonitorLog.TextStyle {
        switch kind {
        case .agentMessage:
            .body
        case .command:
            .body
        case .commandOutput:
            .terminalOutput
        case .plan, .todoList:
            .body
        case .reasoning, .reasoningSummary, .rawReasoning:
            .body
        case .toolCall:
            .body
        case .diagnostic, .error:
            .body
        case .progress, .event:
            .event
        case .contextCompaction:
            .contextCompaction
        }
    }

    private static func decorationStyle(
        for kind: ReviewMonitorLog.Kind,
        source: String,
        metadata: ReviewMonitorLog.Metadata?
    ) -> ReviewMonitorLog.DecorationStyle {
        let tone = statusTone(for: metadata)
        switch kind {
        case .agentMessage:
            return .transcript
        case .command:
            return .command(tone: tone)
        case .commandOutput:
            return .terminal(tone: tone)
        case .plan, .todoList:
            return .plan(tone: tone)
        case .reasoning, .reasoningSummary, .rawReasoning:
            return .reasoning
        case .toolCall:
            return .tool(tone: tone)
        case .diagnostic:
            return .diagnostic(tone: tone)
        case .error:
            return .error
        case .progress, .event:
            return .event
        case .contextCompaction:
            return .contextCompaction(
                label: source,
                isCompleted: contextCompactionIsCompleted(metadata)
            )
        }
    }

    private static func contextCompactionIsCompleted(_ metadata: ReviewMonitorLog.Metadata?) -> Bool {
        let normalized = metadata?.status?
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
        switch normalized {
        case "completed", "complete", "succeeded", "success":
            return true
        case "failed", "failure", "errored", "error", "cancelled", "canceled", "interrupted":
            return false
        default:
            return metadata?.completedAt != nil
        }
    }

    private static func statusTone(for metadata: ReviewMonitorLog.Metadata?) -> ReviewMonitorLog.StatusTone {
        if let exitCode = metadata?.exitCode {
            return exitCode == 0 ? .success : .failure
        }

        let normalized = metadata?.status?
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
        switch normalized {
        case "started", "running", "inprogress":
            return .running
        case "completed", "complete", "succeeded", "success", "passed", "applied":
            return .success
        case "failed", "failure", "errored", "error", "cancelled", "canceled", "interrupted":
            return .failure
        case "warning", "warn", "updated":
            return .warning
        default:
            return .neutral
        }
    }

    private static func renderMarkdown(
        _ source: String,
        blockID: ReviewMonitorLog.BlockID
    ) -> Presentation {
        guard containsMarkdownSyntax(in: source) else {
            return .init(text: source)
        }

        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .full
        options.failurePolicy = .returnPartiallyParsedIfPossible

        guard let attributed = try? AttributedString(markdown: source, options: options) else {
            return .init(text: source)
        }

        var builder = MarkdownPresentationBuilder(blockID: blockID)
        for run in attributed.runs {
            let text = String(attributed[run.range].characters)
            let context = MarkdownContext(presentationIntent: run.presentationIntent)
            builder.append(text, context: context, inlineIntent: run.inlinePresentationIntent, link: run.link)
        }
        let presentation = builder.finish()
        if presentation.text.isEmpty, source.isEmpty == false {
            return .init(text: source)
        }
        return presentation
    }

    private static func containsMarkdownSyntax(in source: String) -> Bool {
        if source.contains("```") || source.contains("`") || source.contains("**") || source.contains("__")
            || source.contains("~~") || source.contains("](")
        {
            return true
        }

        let nsSource = source as NSString
        let fullRange = NSRange(location: 0, length: nsSource.length)
        let blockPatterns = [
            #"(?m)^\s{0,3}#{1,6}\s+"#,
            #"(?m)^\s{0,3}>\s?"#,
            #"(?m)^\s{0,3}(?:[-*+]|\d+[.)])\s+"#,
            #"(?m)^\s{0,3}(?:---+|\*\*\*+|___+)\s*$"#,
            #"(?m)^\s*\|.+\|\s*$"#,
            #"(^|[\s([{])\*[^*\n]+\*($|[\s.,;:!?)\]}])"#,
            #"(^|[\s([{])_[^_\n]+_($|[\s.,;:!?)\]}])"#,
        ]
        for pattern in blockPatterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else {
                continue
            }
            if expression.firstMatch(in: source, options: [], range: fullRange) != nil {
                return true
            }
        }
        return false
    }

    private static func renderPlan(_ source: String) -> Presentation {
        var result = Presentation(text: "")
        var offset = 0
        let lines = source.components(separatedBy: "\n")
        for index in lines.indices {
            if index > lines.startIndex {
                result.text += "\n"
                offset += 1
            }

            let line = lines[index]
            let renderedLine: String
            let status: ReviewMonitorLog.PlanStatus?
            if let parsed = planStatusAndContent(in: line) {
                status = parsed.status
                renderedLine = planMarker(for: parsed.status) + parsed.content
            } else {
                status = nil
                renderedLine = line
            }

            let length = utf16Length(renderedLine)
            if length > 0, status != nil {
                result.styleRuns.append(
                    .init(
                        range: NSRange(location: offset, length: length),
                        style: .plan(status: status)
                    ))
            }
            result.text += renderedLine
            offset += length
        }
        return result
    }

    private static func offset(_ range: NSRange, by location: Int, limitingTo length: Int) -> NSRange {
        let local = NSIntersectionRange(range, NSRange(location: 0, length: length))
        guard local.length > 0 else {
            return NSRange(location: location, length: 0)
        }
        return NSRange(location: location + local.location, length: local.length)
    }

    private static func planStatus(in line: String) -> ReviewMonitorLog.PlanStatus? {
        planStatusAndContent(in: line)?.status
    }

    private static func planStatusAndContent(in line: String) -> (status: ReviewMonitorLog.PlanStatus, content: String)?
    {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["),
            let closingIndex = trimmed.firstIndex(of: "]")
        else {
            return nil
        }
        let rawStatus = trimmed[trimmed.index(after: trimmed.startIndex)..<closingIndex]
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
        switch rawStatus {
        case "pending":
            return (.pending, planContent(after: closingIndex, in: trimmed))
        case "inprogress":
            return (.inProgress, planContent(after: closingIndex, in: trimmed))
        case "completed", "complete", "done":
            return (.completed, planContent(after: closingIndex, in: trimmed))
        case "failed", "failure", "error":
            return (.failed, planContent(after: closingIndex, in: trimmed))
        default:
            return nil
        }
    }

    private static func planContent(after closingIndex: String.Index, in line: String) -> String {
        let start = line.index(after: closingIndex)
        return line[start...].trimmingCharacters(in: .whitespaces)
    }

    private static func planMarker(for status: ReviewMonitorLog.PlanStatus) -> String {
        switch status {
        case .completed:
            return "\u{2713} "
        case .inProgress:
            return "\u{2022} "
        case .pending:
            return "\u{25A1} "
        case .failed:
            return "! "
        }
    }

    private static func utf16Length(_ text: String) -> Int {
        (text as NSString).length
    }

    private struct MarkdownContext: Equatable {
        enum Kind: Equatable {
            case paragraph
            case heading(level: Int)
            case unorderedListItem(ordinal: Int, listIdentity: Int)
            case orderedListItem(ordinal: Int, listIdentity: Int)
            case blockquote
            case codeBlock(languageHint: String?)
            case thematicBreak
            case table
        }

        var identity: Int
        var kind: Kind

        init(presentationIntent: PresentationIntent?) {
            let components = presentationIntent?.components ?? []
            var codeBlock: (identity: Int, languageHint: String?)?
            var header: (identity: Int, level: Int)?
            var listItem: (identity: Int, ordinal: Int)?
            var orderedListIdentity: Int?
            var unorderedListIdentity: Int?
            var blockquoteIdentity: Int?
            var thematicBreakIdentity: Int?
            var paragraphIdentity: Int?
            var tableIdentity: Int?
            var tableCellIdentity: Int?

            for component in components {
                switch component.kind {
                case .codeBlock(let languageHint):
                    if codeBlock == nil {
                        codeBlock = (component.identity, languageHint)
                    }
                case .header(let level):
                    if header == nil {
                        header = (component.identity, level)
                    }
                case .listItem(let ordinal):
                    if listItem == nil {
                        listItem = (component.identity, ordinal)
                    }
                case .orderedList:
                    if orderedListIdentity == nil {
                        orderedListIdentity = component.identity
                    }
                case .unorderedList:
                    if unorderedListIdentity == nil {
                        unorderedListIdentity = component.identity
                    }
                case .blockQuote:
                    if blockquoteIdentity == nil {
                        blockquoteIdentity = component.identity
                    }
                case .thematicBreak:
                    if thematicBreakIdentity == nil {
                        thematicBreakIdentity = component.identity
                    }
                case .paragraph:
                    if paragraphIdentity == nil {
                        paragraphIdentity = component.identity
                    }
                case .table:
                    if tableIdentity == nil {
                        tableIdentity = component.identity
                    }
                case .tableCell:
                    if tableCellIdentity == nil {
                        tableCellIdentity = component.identity
                    }
                case .tableHeaderRow, .tableRow:
                    break
                @unknown default:
                    break
                }
            }

            if let codeBlock {
                self.identity = codeBlock.identity
                self.kind = .codeBlock(languageHint: codeBlock.languageHint)
                return
            }
            if let header {
                self.identity = header.identity
                self.kind = .heading(level: header.level)
                return
            }
            if let listItem {
                self.identity = listItem.identity
                if let orderedListIdentity {
                    self.kind = .orderedListItem(ordinal: listItem.ordinal, listIdentity: orderedListIdentity)
                } else if let unorderedListIdentity {
                    self.kind = .unorderedListItem(ordinal: listItem.ordinal, listIdentity: unorderedListIdentity)
                } else {
                    self.kind = .unorderedListItem(ordinal: listItem.ordinal, listIdentity: listItem.identity)
                }
                return
            }
            if let blockquoteIdentity {
                self.identity = paragraphIdentity ?? blockquoteIdentity
                self.kind = .blockquote
                return
            }
            if let thematicBreakIdentity {
                self.identity = thematicBreakIdentity
                self.kind = .thematicBreak
                return
            }
            if let tableIdentity {
                self.identity = tableCellIdentity ?? tableIdentity
                self.kind = .table
                return
            }

            self.identity = paragraphIdentity ?? 0
            self.kind = .paragraph
        }

        var isCodeBlock: Bool {
            if case .codeBlock = kind {
                return true
            }
            return false
        }

        var blockStyle: ReviewMonitorLog.TextStyle? {
            switch kind {
            case .paragraph:
                return nil
            case .heading(let level):
                return .heading(level: level)
            case .unorderedListItem, .orderedListItem:
                return .bullet
            case .blockquote:
                return .blockquote
            case .codeBlock:
                return .codeFence
            case .thematicBreak:
                return .muted
            case .table:
                return .body
            }
        }

        func separator(after previous: MarkdownContext?) -> Int {
            guard let previous, previous != self else {
                return 0
            }
            switch (previous.kind, kind) {
            case (.unorderedListItem(_, let previousList), .unorderedListItem(_, let currentList))
            where previousList == currentList:
                return 1
            case (.orderedListItem(_, let previousList), .orderedListItem(_, let currentList))
            where previousList == currentList:
                return 1
            default:
                return 2
            }
        }

        var prefix: String {
            switch kind {
            case .unorderedListItem:
                return "- "
            case .orderedListItem(let ordinal, _):
                return "\(ordinal). "
            case .paragraph, .heading, .blockquote, .codeBlock, .thematicBreak, .table:
                return ""
            }
        }
    }

    private struct MarkdownPresentationBuilder {
        var blockID: ReviewMonitorLog.BlockID
        var text = ""
        var utf16Offset = 0
        var styleRuns: [ReviewMonitorLog.TextRun] = []
        var decorations: [ReviewMonitorLog.Decoration] = []
        var currentContext: MarkdownContext?
        var activeCodeBlockStart: Int?

        mutating func append(
            _ segment: String,
            context: MarkdownContext,
            inlineIntent: InlinePresentationIntent?,
            link: URL?
        ) {
            if currentContext != context {
                closeCodeBlockIfNeeded()
                appendNewlines(context.separator(after: currentContext))
                appendPrefix(for: context)
                if context.isCodeBlock {
                    activeCodeBlockStart = utf16Offset
                }
                currentContext = context
            }

            let range = appendRaw(segment)
            guard range.length > 0 else {
                return
            }

            if let style = context.blockStyle {
                styleRuns.append(.init(range: range, style: style))
            }
            appendInlineStyles(in: range, inlineIntent: inlineIntent, link: link)
        }

        mutating func finish() -> Presentation {
            closeCodeBlockIfNeeded()
            return .init(text: text, styleRuns: styleRuns, decorations: decorations)
        }

        private mutating func appendPrefix(for context: MarkdownContext) {
            let prefix = context.prefix
            guard prefix.isEmpty == false else {
                return
            }
            let range = appendRaw(prefix)
            if range.length > 0, let style = context.blockStyle {
                styleRuns.append(.init(range: range, style: style))
            }
        }

        private mutating func appendNewlines(_ count: Int) {
            guard count > 0 else {
                return
            }
            let existing = trailingNewlineCount()
            let needed = max(0, count - existing)
            guard needed > 0 else {
                return
            }
            _ = appendRaw(String(repeating: "\n", count: needed))
        }

        private mutating func appendRaw(_ string: String) -> NSRange {
            let length = ReviewMonitorLogStyler.utf16Length(string)
            let range = NSRange(location: utf16Offset, length: length)
            text += string
            utf16Offset += length
            return range
        }

        private mutating func appendInlineStyles(
            in range: NSRange,
            inlineIntent: InlinePresentationIntent?,
            link: URL?
        ) {
            if let inlineIntent {
                if inlineIntent.contains(.stronglyEmphasized) {
                    styleRuns.append(.init(range: range, style: .strong))
                }
                if inlineIntent.contains(.emphasized) {
                    styleRuns.append(.init(range: range, style: .emphasis))
                }
                if inlineIntent.contains(.code) {
                    styleRuns.append(.init(range: range, style: .inlineCode))
                }
                if inlineIntent.contains(.strikethrough) {
                    styleRuns.append(.init(range: range, style: .strikethrough))
                }
            }
            if link != nil {
                styleRuns.append(.init(range: range, style: .link))
            }
        }

        private mutating func closeCodeBlockIfNeeded() {
            guard let start = activeCodeBlockStart else {
                return
            }
            let range = NSRange(location: start, length: max(0, utf16Offset - start))
            if range.length > 0 {
                decorations.append(.init(blockID: blockID, range: range, style: .codeBlock))
            }
            activeCodeBlockStart = nil
        }

        private func trailingNewlineCount() -> Int {
            var count = 0
            for character in text.reversed() {
                guard character == "\n" else {
                    return count
                }
                count += 1
            }
            return count
        }
    }

}
