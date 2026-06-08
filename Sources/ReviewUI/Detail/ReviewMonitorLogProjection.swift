import Foundation
import CodexReview

struct ReviewMonitorLogBlockID: Codable, Hashable, Sendable {
    var rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

struct ReviewMonitorLogBlock: Equatable, Sendable {
    var id: ReviewMonitorLogBlockID
    var kind: ReviewLogEntry.Kind
    var groupID: String?
    var range: NSRange
    var sourceRange: NSRange
    var metadata: ReviewLogEntry.Metadata?
    var contentBlocks: [ReviewLogEntry.ContentBlock]

    init(
        id: ReviewMonitorLogBlockID,
        kind: ReviewLogEntry.Kind,
        groupID: String?,
        range: NSRange,
        sourceRange: NSRange? = nil,
        metadata: ReviewLogEntry.Metadata? = nil,
        contentBlocks: [ReviewLogEntry.ContentBlock] = []
    ) {
        self.id = id
        self.kind = kind
        self.groupID = groupID
        self.range = range
        self.sourceRange = sourceRange ?? range
        self.metadata = metadata
        self.contentBlocks = contentBlocks
    }
}

enum ReviewMonitorLogStatusTone: Hashable, Sendable {
    case neutral
    case running
    case success
    case warning
    case failure
}

enum ReviewMonitorLogPlanStatus: String, Hashable, Sendable {
    case pending
    case inProgress
    case completed
    case failed
}

enum ReviewMonitorLogTextStyle: Hashable, Sendable {
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
    case plan(status: ReviewMonitorLogPlanStatus?)
    case tool
    case diagnostic
    case error
    case event
    case contextCompaction
    case muted
}

struct ReviewMonitorLogTextRun: Equatable, Sendable {
    var range: NSRange
    var style: ReviewMonitorLogTextStyle
}

enum ReviewMonitorLogDecorationStyle: Hashable, Sendable {
    case transcript
    case command(tone: ReviewMonitorLogStatusTone)
    case terminal(tone: ReviewMonitorLogStatusTone)
    case codeBlock
    case plan(tone: ReviewMonitorLogStatusTone)
    case reasoning
    case tool(tone: ReviewMonitorLogStatusTone)
    case diagnostic(tone: ReviewMonitorLogStatusTone)
    case error
    case event
    case contextCompaction(label: String, isCompleted: Bool)
}

struct ReviewMonitorLogDecoration: Equatable, Sendable {
    var blockID: ReviewMonitorLogBlockID
    var range: NSRange
    var style: ReviewMonitorLogDecorationStyle
}

struct ReviewMonitorLogPanel: Equatable, Hashable, Sendable {
    enum Payload: Equatable, Hashable, Sendable {
        case terminal(Terminal)
        case syntax(Syntax)
    }

    struct Terminal: Equatable, Hashable, Sendable {
        var commandText: String
        var outputText: String
        var lineCount: Int
        var isActive: Bool
        var startedAt: Date?
        var exitText: String?
    }

    struct Syntax: Equatable, Hashable, Sendable {
        var text: String
        var languageHint: String?
        var tone: ReviewMonitorLogStatusTone
    }

    var blockID: ReviewMonitorLogBlockID
    var range: NSRange
    var isExpanded: Bool
    var title: String
    var payload: Payload

    var terminal: Terminal? {
        guard case .terminal(let terminal) = payload else { return nil }
        return terminal
    }

    var syntax: Syntax? {
        guard case .syntax(let syntax) = payload else { return nil }
        return syntax
    }

    var isActive: Bool {
        terminal?.isActive ?? false
    }

    var startedAt: Date? {
        terminal?.startedAt
    }

    var exitText: String? {
        get {
            terminal?.exitText
        }
        set {
            guard case .terminal(var terminal) = payload else {
                return
            }
            terminal.exitText = newValue
            payload = .terminal(terminal)
        }
    }

    var commandText: String {
        get {
            terminal?.commandText ?? ""
        }
        set {
            guard case .terminal(var terminal) = payload else {
                return
            }
            terminal.commandText = newValue
            payload = .terminal(terminal)
        }
    }

    var outputText: String {
        get {
            switch payload {
            case .terminal(let terminal):
                terminal.outputText
            case .syntax(let syntax):
                syntax.text
            }
        }
        set {
            switch payload {
            case .terminal(var terminal):
                terminal.outputText = newValue
                terminal.lineCount = Self.lineCount(newValue)
                payload = .terminal(terminal)
            case .syntax(var syntax):
                syntax.text = newValue
                payload = .syntax(syntax)
            }
        }
    }

    var lineCount: Int {
        get {
            switch payload {
            case .terminal(let terminal):
                terminal.lineCount
            case .syntax(let syntax):
                Self.lineCount(syntax.text)
            }
        }
        set {
            guard case .terminal(var terminal) = payload else {
                return
            }
            terminal.lineCount = newValue
            payload = .terminal(terminal)
        }
    }

    func collapsedPayload() -> ReviewMonitorLogPanel {
        var collapsed = self
        switch collapsed.payload {
        case .terminal(var terminal):
            terminal.commandText = ""
            terminal.outputText = ""
            terminal.lineCount = 0
            terminal.exitText = nil
            collapsed.payload = .terminal(terminal)
        case .syntax(var syntax):
            syntax.text = ""
            collapsed.payload = .syntax(syntax)
        }
        return collapsed
    }

    private static func lineCount(_ text: String) -> Int {
        guard text.isEmpty == false else {
            return 0
        }
        let rawLineCount = text.split(separator: "\n", omittingEmptySubsequences: false).count
        return text.hasSuffix("\n") ? max(0, rawLineCount - 1) : rawLineCount
    }
}

struct ReviewMonitorLogAppend: Equatable, Sendable {
    var kind: ReviewLogEntry.Kind
    var blockID: ReviewMonitorLogBlockID
    var range: NSRange
    var text: String
    var textUTF16Length: Int

    init(
        kind: ReviewLogEntry.Kind,
        blockID: ReviewMonitorLogBlockID,
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

struct ReviewMonitorLogReplacement: Equatable, Sendable {
    var kind: ReviewLogEntry.Kind
    var blockID: ReviewMonitorLogBlockID
    var range: NSRange
    var text: String
    var textUTF16Length: Int

    init(
        kind: ReviewLogEntry.Kind,
        blockID: ReviewMonitorLogBlockID,
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

enum ReviewMonitorLogChange: Equatable, Sendable {
    case reload
    case append(ReviewMonitorLogAppend)
    case replace(ReviewMonitorLogReplacement)
}

struct ReviewMonitorLogDocument: Equatable, Sendable {
    var text: String
    var textUTF16Length: Int
    var sourceText: String
    var sourceTextUTF16Length: Int
    var blocks: [ReviewMonitorLogBlock]
    var styleRuns: [ReviewMonitorLogTextRun]
    var decorations: [ReviewMonitorLogDecoration]
    var panels: [ReviewMonitorLogPanel]
    var revision: UInt64
    var lastChange: ReviewMonitorLogChange

    init(
        text: String = "",
        textUTF16Length: Int? = nil,
        sourceText: String? = nil,
        sourceTextUTF16Length: Int? = nil,
        blocks: [ReviewMonitorLogBlock] = [],
        styleRuns: [ReviewMonitorLogTextRun] = [],
        decorations: [ReviewMonitorLogDecoration] = [],
        panels: [ReviewMonitorLogPanel] = [],
        revision: UInt64 = 0,
        lastChange: ReviewMonitorLogChange = .reload
    ) {
        self.text = text
        self.textUTF16Length = textUTF16Length ?? Self.utf16Length(text)
        self.sourceText = sourceText ?? text
        self.sourceTextUTF16Length = sourceTextUTF16Length ?? Self.utf16Length(sourceText ?? text)
        self.blocks = blocks
        self.styleRuns = styleRuns
        self.decorations = decorations
        self.panels = panels
        self.revision = revision
        self.lastChange = lastChange
    }

    private static func utf16Length(_ text: String) -> Int {
        (text as NSString).length
    }

    mutating func rebuildPresentation() {
        styleRuns.removeAll(keepingCapacity: true)
        decorations.removeAll(keepingCapacity: true)
        panels.removeAll(keepingCapacity: true)
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
        panels.removeAll {
            $0.blockID == block.id || NSIntersectionRange($0.range, block.range).length > 0
        }
        ReviewMonitorLogStyler.appendPresentation(for: block, to: &self)
    }

    var finderSupplementSignature: Int {
        var hasher = Hasher()
        for panel in panels {
            hasher.combine(panel.blockID)
            combine(panel.range, into: &hasher)
            hasher.combine(panel.payload)
        }
        return hasher.finalize()
    }

    private func combine(_ range: NSRange, into hasher: inout Hasher) {
        hasher.combine(range.location)
        hasher.combine(range.length)
    }
}

private enum ReviewMonitorLogStyler {
    struct Presentation {
        var text: String
        var styleRuns: [ReviewMonitorLogTextRun] = []
        var decorations: [ReviewMonitorLogDecoration] = []
    }

    static func renderedText(
        for kind: ReviewLogEntry.Kind,
        source: String,
        blockID: ReviewMonitorLogBlockID
    ) -> String {
        presentation(for: kind, source: source, blockID: blockID).text
    }

    static func appendPresentation(for block: ReviewMonitorLogBlock, to document: inout ReviewMonitorLogDocument) {
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
            document.decorations.append(.init(
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
            document.decorations.append(.init(
                blockID: decoration.blockID,
                range: range,
                style: decoration.style
            ))
        }
    }

    private static func presentation(
        for kind: ReviewLogEntry.Kind,
        source: String,
        blockID: ReviewMonitorLogBlockID
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

    private static func baseTextStyle(for kind: ReviewLogEntry.Kind) -> ReviewMonitorLogTextStyle {
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
        for kind: ReviewLogEntry.Kind,
        source: String,
        metadata: ReviewLogEntry.Metadata?
    ) -> ReviewMonitorLogDecorationStyle {
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

    private static func contextCompactionIsCompleted(_ metadata: ReviewLogEntry.Metadata?) -> Bool {
        let normalized = metadata?.status?
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
        switch normalized {
        case "completed", "complete", "succeeded", "success":
            return true
        case "failed", "failure", "errored", "error", "cancelled", "canceled":
            return false
        default:
            return metadata?.completedAt != nil
        }
    }

    private static func statusTone(for metadata: ReviewLogEntry.Metadata?) -> ReviewMonitorLogStatusTone {
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
        case "failed", "failure", "errored", "error", "cancelled", "canceled":
            return .failure
        case "warning", "warn", "updated":
            return .warning
        default:
            return .neutral
        }
    }

    private static func renderMarkdown(
        _ source: String,
        blockID: ReviewMonitorLogBlockID
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
        if source.contains("```") ||
            source.contains("`") ||
            source.contains("**") ||
            source.contains("__") ||
            source.contains("~~") ||
            source.contains("](") {
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
            let status: ReviewMonitorLogPlanStatus?
            if let parsed = planStatusAndContent(in: line) {
                status = parsed.status
                renderedLine = planMarker(for: parsed.status) + parsed.content
            } else {
                status = nil
                renderedLine = line
            }

            let length = utf16Length(renderedLine)
            if length > 0, status != nil {
                result.styleRuns.append(.init(
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

    private static func planStatus(in line: String) -> ReviewMonitorLogPlanStatus? {
        planStatusAndContent(in: line)?.status
    }

    private static func planStatusAndContent(in line: String) -> (status: ReviewMonitorLogPlanStatus, content: String)? {
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

    private static func planMarker(for status: ReviewMonitorLogPlanStatus) -> String {
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

        var blockStyle: ReviewMonitorLogTextStyle? {
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
        var blockID: ReviewMonitorLogBlockID
        var text = ""
        var utf16Offset = 0
        var styleRuns: [ReviewMonitorLogTextRun] = []
        var decorations: [ReviewMonitorLogDecoration] = []
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

struct ReviewMonitorLogProjection: Sendable {
    private struct GroupKey: Hashable, Sendable {
        var kind: ReviewLogEntry.Kind
        var groupID: String
    }

    private struct RenderedBlock: Sendable {
        var id: ReviewMonitorLogBlockID
        var kind: ReviewLogEntry.Kind
        var groupID: String?
        var text: String
        var metadata: ReviewLogEntry.Metadata?
        var contentBlocks: [ReviewLogEntry.ContentBlock]
    }

    private struct EntrySignature: Equatable, Sendable {
        var id: UUID
        var kind: ReviewLogEntry.Kind
        var groupID: String?
        var replacesGroup: Bool
        var textUTF16Length: Int
        var textHash: Int
        var metadataHash: Int?
        var contentBlocksHash: Int
        var timestamp: Date

        init(_ entry: ReviewLogEntry) {
            var textHasher = Hasher()
            textHasher.combine(entry.text)
            if let metadata = entry.metadata {
                var metadataHasher = Hasher()
                metadataHasher.combine(metadata)
                metadataHash = metadataHasher.finalize()
            } else {
                metadataHash = nil
            }
            self.id = entry.id
            self.kind = entry.kind
            self.groupID = entry.groupID
            self.replacesGroup = entry.replacesGroup
            self.textUTF16Length = ReviewMonitorLogProjection.utf16Length(entry.text)
            self.textHash = textHasher.finalize()
            var contentBlocksHasher = Hasher()
            contentBlocksHasher.combine(entry.contentBlocks)
            self.contentBlocksHash = contentBlocksHasher.finalize()
            self.timestamp = entry.timestamp
        }
    }

    private enum AppendResult: Sendable {
        case noVisibleChange
        case changed(ReviewMonitorLogChange)
        case needsReload(replacementBlockID: ReviewMonitorLogBlockID?)
    }

    private struct Accumulator: Sendable {
        private(set) var document = ReviewMonitorLogDocument()
        private(set) var hasVisibleSections = false
        private(set) var lastBlockIndex: Int?

        mutating func appendBlock(
            _ block: RenderedBlock,
            at blockIndex: Int
        ) -> ReviewMonitorLogAppend {
            let renderedText = ReviewMonitorLogStyler.renderedText(
                for: block.kind,
                source: block.text,
                blockID: block.id
            )
            let appended = appendedText(
                renderedText,
                after: document.text
            )
            let appendedSource = appendedText(
                block.text,
                after: document.sourceText
            )
            if hasVisibleSections == false {
                hasVisibleSections = true
            }

            let previousLength = document.textUTF16Length
            let previousSourceLength = document.sourceTextUTF16Length
            let suffixLength = ReviewMonitorLogProjection.utf16Length(appended)
            let sourceSuffixLength = ReviewMonitorLogProjection.utf16Length(appendedSource)
            let blockLength = ReviewMonitorLogProjection.utf16Length(renderedText)
            let sourceBlockLength = ReviewMonitorLogProjection.utf16Length(block.text)
            let blockRange = NSRange(
                location: previousLength + max(0, suffixLength - blockLength),
                length: blockLength
            )
            let sourceBlockRange = NSRange(
                location: previousSourceLength + max(0, sourceSuffixLength - sourceBlockLength),
                length: sourceBlockLength
            )

            document.text += appended
            document.textUTF16Length += suffixLength
            document.sourceText += appendedSource
            document.sourceTextUTF16Length += sourceSuffixLength
            let logBlock = ReviewMonitorLogBlock(
                id: block.id,
                kind: block.kind,
                groupID: block.groupID,
                range: blockRange,
                sourceRange: sourceBlockRange,
                metadata: block.metadata,
                contentBlocks: block.contentBlocks
            )
            document.blocks.append(logBlock)
            ReviewMonitorLogStyler.appendPresentation(for: logBlock, to: &document)
            lastBlockIndex = blockIndex
            return .init(
                kind: block.kind,
                blockID: block.id,
                range: blockRange,
                text: appended,
                textUTF16Length: suffixLength
            )
        }

        mutating func appendToCurrentBlock(
            _ block: RenderedBlock,
            at blockIndex: Int,
            sourceDelta: String,
            renderedDelta: String
        ) -> ReviewMonitorLogAppend? {
            guard renderedDelta.isEmpty == false,
                  let blockIndexInDocument = document.blocks.lastIndex(where: { $0.id == block.id })
            else {
                return nil
            }

            let previousLength = document.textUTF16Length
            let deltaLength = ReviewMonitorLogProjection.utf16Length(renderedDelta)
            let sourceDeltaLength = ReviewMonitorLogProjection.utf16Length(sourceDelta)
            document.text += renderedDelta
            document.textUTF16Length += deltaLength
            document.sourceText += sourceDelta
            document.sourceTextUTF16Length += sourceDeltaLength
            document.blocks[blockIndexInDocument].range.length += deltaLength
            document.blocks[blockIndexInDocument].sourceRange.length += sourceDeltaLength
            document.blocks[blockIndexInDocument].metadata = block.metadata
            document.blocks[blockIndexInDocument].contentBlocks = block.contentBlocks
            document.rebuildPresentation(forBlockAt: blockIndexInDocument)
            lastBlockIndex = blockIndex
            return .init(
                kind: block.kind,
                blockID: block.id,
                range: NSRange(location: previousLength, length: document.textUTF16Length - previousLength),
                text: renderedDelta,
                textUTF16Length: document.textUTF16Length - previousLength
            )
        }

        mutating func replaceCurrentBlock(
            _ block: RenderedBlock,
            at blockIndex: Int
        ) -> ReviewMonitorLogReplacement? {
            guard let blockIndexInDocument = document.blocks.lastIndex(where: { $0.id == block.id })
            else {
                return nil
            }

            let previousBlock = document.blocks[blockIndexInDocument]
            guard NSMaxRange(previousBlock.range) == document.textUTF16Length,
                  NSMaxRange(previousBlock.sourceRange) == document.sourceTextUTF16Length
            else {
                return nil
            }

            let renderedText = ReviewMonitorLogStyler.renderedText(
                for: block.kind,
                source: block.text,
                blockID: block.id
            )
            let renderedLength = ReviewMonitorLogProjection.utf16Length(renderedText)
            let sourceLength = ReviewMonitorLogProjection.utf16Length(block.text)
            let textPrefix = (document.text as NSString).substring(
                with: NSRange(location: 0, length: previousBlock.range.location)
            )
            let sourcePrefix = (document.sourceText as NSString).substring(
                with: NSRange(location: 0, length: previousBlock.sourceRange.location)
            )

            document.text = textPrefix + renderedText
            document.textUTF16Length = previousBlock.range.location + renderedLength
            document.sourceText = sourcePrefix + block.text
            document.sourceTextUTF16Length = previousBlock.sourceRange.location + sourceLength
            document.blocks[blockIndexInDocument] = ReviewMonitorLogBlock(
                id: block.id,
                kind: block.kind,
                groupID: block.groupID,
                range: NSRange(location: previousBlock.range.location, length: renderedLength),
                sourceRange: NSRange(location: previousBlock.sourceRange.location, length: sourceLength),
                metadata: block.metadata,
                contentBlocks: block.contentBlocks
            )
            document.styleRuns.removeAll {
                $0.range.location >= previousBlock.range.location ||
                    NSIntersectionRange($0.range, previousBlock.range).length > 0
            }
            document.decorations.removeAll {
                $0.blockID == block.id ||
                    $0.range.location >= previousBlock.range.location ||
                    NSIntersectionRange($0.range, previousBlock.range).length > 0
            }
            ReviewMonitorLogStyler.appendPresentation(for: document.blocks[blockIndexInDocument], to: &document)
            lastBlockIndex = blockIndex
            return .init(
                kind: block.kind,
                blockID: block.id,
                range: previousBlock.range,
                text: renderedText,
                textUTF16Length: renderedLength
            )
        }

        private func appendedText(_ blockText: String, after existingText: String) -> String {
            guard hasVisibleSections else {
                return blockText
            }
            if blockText.isEmpty {
                return "\n\n"
            }
            if existingText.hasSuffix("\n\n") {
                return blockText
            }
            if existingText.hasSuffix("\n") || blockText.hasPrefix("\n") {
                return "\n" + blockText
            }
            return "\n\n" + blockText
        }
    }

    private struct State: Sendable {
        var entrySignatures: [EntrySignature]
        var blocks: [RenderedBlock]
        var indexByGroup: [GroupKey: Int]
        var projection: Accumulator

        init(entries: [ReviewLogEntry]) {
            self = Self.rebuild(entries: entries)
        }

        var document: ReviewMonitorLogDocument {
            projection.document
        }

        static func rebuild(entries: [ReviewLogEntry]) -> State {
            var state = State(
                entrySignatures: entries.map(EntrySignature.init),
                blocks: [],
                indexByGroup: [:],
                projection: .init()
            )

            for entry in entries {
                if let key = ReviewMonitorLogProjection.mergeKey(for: entry) {
                    if let index = state.indexByGroup[key] {
                        if entry.replacesGroup {
                            state.blocks[index].text = entry.text
                            state.blocks[index].metadata = entry.metadata
                            state.blocks[index].contentBlocks = entry.contentBlocks
                        } else {
                            state.blocks[index].text.append(entry.text)
                            if let metadata = entry.metadata {
                                state.blocks[index].metadata = metadata
                            }
                            state.blocks[index].contentBlocks.append(contentsOf: entry.contentBlocks)
                        }
                        continue
                    }
                    state.indexByGroup[key] = state.blocks.count
                }
                if let key = ReviewMonitorLogProjection.replacementOnlyKey(for: entry) {
                    if entry.replacesGroup,
                       let index = state.indexByGroup[key] {
                        state.blocks[index].text = entry.text
                        state.blocks[index].metadata = entry.metadata
                        state.blocks[index].contentBlocks = entry.contentBlocks
                        continue
                    }
                    if state.indexByGroup[key] == nil {
                        state.indexByGroup[key] = state.blocks.count
                    }
                }

                state.blocks.append(.init(
                    id: ReviewMonitorLogProjection.blockID(for: entry),
                    kind: entry.kind,
                    groupID: entry.groupID,
                    text: entry.text,
                    metadata: entry.metadata,
                    contentBlocks: entry.contentBlocks
                ))
            }

            for (index, block) in state.blocks.enumerated() {
                _ = state.appendBlock(block, at: index)
            }
            return state
        }

        private init(
            entrySignatures: [EntrySignature],
            blocks: [RenderedBlock],
            indexByGroup: [GroupKey: Int],
            projection: Accumulator
        ) {
            self.entrySignatures = entrySignatures
            self.blocks = blocks
            self.indexByGroup = indexByGroup
            self.projection = projection
        }

        mutating func append(_ entry: ReviewLogEntry) -> AppendResult {
            entrySignatures.append(.init(entry))

            if let key = ReviewMonitorLogProjection.mergeKey(for: entry) {
                if let blockIndex = indexByGroup[key] {
                    let oldText = blocks[blockIndex].text
                    if entry.replacesGroup || blockIndex != blocks.indices.last {
                        return .needsReload(
                            replacementBlockID: entry.replacesGroup ? blocks[blockIndex].id : nil
                        )
                    }

                    blocks[blockIndex].text.append(entry.text)
                    if let metadata = entry.metadata {
                        blocks[blockIndex].metadata = metadata
                    }
                    blocks[blockIndex].contentBlocks.append(contentsOf: entry.contentBlocks)
                    let newText = blocks[blockIndex].text
                    let wasVisible = ReviewMonitorLogProjection.isVisible(kind: entry.kind, text: oldText)
                    let isVisible = ReviewMonitorLogProjection.isVisible(kind: entry.kind, text: newText)
                    if wasVisible,
                       isVisible,
                       ReviewMonitorLogProjection.requiresBlockRerenderOnDelta(kind: entry.kind) {
                        let blockID = blocks[blockIndex].id
                        let oldRendered = ReviewMonitorLogStyler.renderedText(
                            for: entry.kind,
                            source: oldText,
                            blockID: blockID
                        )
                        let newRendered = ReviewMonitorLogStyler.renderedText(
                            for: entry.kind,
                            source: newText,
                            blockID: blockID
                        )
                        if let renderedDelta = ReviewMonitorLogProjection.suffix(
                            in: newRendered,
                            afterPrefix: oldRendered
                        ) {
                            if let append = projection.appendToCurrentBlock(
                                blocks[blockIndex],
                                at: blockIndex,
                                sourceDelta: entry.text,
                                renderedDelta: renderedDelta
                            ) {
                                return .changed(.append(append))
                            }
                            if let replacement = projection.replaceCurrentBlock(
                                blocks[blockIndex],
                                at: blockIndex
                            ) {
                                return .changed(.replace(replacement))
                            }
                            return .noVisibleChange
                        }
                        if let replacement = projection.replaceCurrentBlock(
                            blocks[blockIndex],
                            at: blockIndex
                        ) {
                            return .changed(.replace(replacement))
                        }
                        return .needsReload(replacementBlockID: blockID)
                    }
                    if let append = appendTailGroupDelta(
                        block: blocks[blockIndex],
                        oldText: oldText,
                        newText: newText,
                        blockIndex: blockIndex,
                        delta: entry.text
                    ) {
                        return .changed(.append(append))
                    }
                    return .noVisibleChange
                }

                indexByGroup[key] = blocks.count
            }
            if let key = ReviewMonitorLogProjection.replacementOnlyKey(for: entry) {
                if entry.replacesGroup,
                   let blockIndex = indexByGroup[key] {
                    return .needsReload(replacementBlockID: blocks[blockIndex].id)
                }
                if indexByGroup[key] == nil {
                    indexByGroup[key] = blocks.count
                }
            }

            let blockIndex = blocks.count
            let block = RenderedBlock(
                id: ReviewMonitorLogProjection.blockID(for: entry),
                kind: entry.kind,
                groupID: entry.groupID,
                text: entry.text,
                metadata: entry.metadata,
                contentBlocks: entry.contentBlocks
            )
            blocks.append(block)
            if let append = appendBlock(block, at: blockIndex) {
                return .changed(.append(append))
            }
            return .noVisibleChange
        }

        private mutating func appendBlock(
            _ block: RenderedBlock,
            at blockIndex: Int
        ) -> ReviewMonitorLogAppend? {
            guard ReviewMonitorLogProjection.isVisible(
                kind: block.kind,
                text: block.text
            ) else {
                return nil
            }
            return projection.appendBlock(block, at: blockIndex)
        }

        private mutating func appendTailGroupDelta(
            block: RenderedBlock,
            oldText: String,
            newText: String,
            blockIndex: Int,
            delta: String
        ) -> ReviewMonitorLogAppend? {
            let wasVisible = ReviewMonitorLogProjection.isVisible(
                kind: block.kind,
                text: oldText
            )
            let isVisible = ReviewMonitorLogProjection.isVisible(
                kind: block.kind,
                text: newText
            )

            switch (wasVisible, isVisible) {
            case (false, false):
                return nil
            case (false, true):
                return projection.appendBlock(block, at: blockIndex)
            case (true, true):
                return projection.appendToCurrentBlock(
                    block,
                    at: blockIndex,
                    sourceDelta: delta,
                    renderedDelta: delta
                )
            case (true, false):
                return nil
            }
        }

        static func replacement(
            previous: ReviewMonitorLogDocument,
            current: ReviewMonitorLogDocument,
            blockID: ReviewMonitorLogBlockID
        ) -> ReviewMonitorLogReplacement? {
            guard let previousBlock = previous.blocks.first(where: { $0.id == blockID }),
                  let currentBlock = current.blocks.first(where: { $0.id == blockID }),
                  previousBlock.range.location == currentBlock.range.location,
                  NSMaxRange(currentBlock.range) <= current.textUTF16Length
            else {
                return nil
            }

            let replacementText = (current.text as NSString).substring(with: currentBlock.range)
            return .init(
                kind: currentBlock.kind,
                blockID: currentBlock.id,
                range: previousBlock.range,
                text: replacementText,
                textUTF16Length: currentBlock.range.length
            )
        }
    }

    private var state = State(entries: [])
    private var document = ReviewMonitorLogDocument()

    var entryCount: Int {
        state.entrySignatures.count
    }

    mutating func render(entries: [ReviewLogEntry]) -> ReviewMonitorLogDocument {
        let entrySignatures = entries.map(EntrySignature.init)
        guard entrySignatures != state.entrySignatures else {
            return document
        }

        let previousDocument = document
        let preferredChange: ReviewMonitorLogChange?
        if entrySignatures.count == state.entrySignatures.count + 1,
           entrySignatures.dropLast().elementsEqual(state.entrySignatures),
           let entry = entries.last {
            switch state.append(entry) {
            case .changed(let change):
                preferredChange = change
            case .noVisibleChange:
                preferredChange = nil
            case .needsReload(let replacementBlockID):
                state = State.rebuild(entries: entries)
                if let replacementBlockID,
                   let replacement = State.replacement(
                       previous: previousDocument,
                       current: state.document,
                       blockID: replacementBlockID
                   ) {
                    preferredChange = .replace(replacement)
                } else {
                    preferredChange = .reload
                }
            }
        } else {
            state = State.rebuild(entries: entries)
            preferredChange = .reload
        }

        if let resolved = Self.resolveDocument(
            previous: previousDocument,
            current: state.document,
            preferredChange: preferredChange
        ) {
            document = resolved
        }
        return document
    }

    mutating func append(
        entries: [ReviewLogEntry],
        sourceRange: Range<Int>
    ) -> ReviewMonitorLogDocument? {
        guard sourceRange.lowerBound <= state.entrySignatures.count else {
            return nil
        }
        guard state.entrySignatures.count < sourceRange.upperBound else {
            return document
        }

        let skipCount = state.entrySignatures.count - sourceRange.lowerBound
        guard skipCount >= 0,
              skipCount <= entries.count
        else {
            return nil
        }

        for entry in entries.dropFirst(skipCount) {
            let previousDocument = document
            let previousState = state
            switch state.append(entry) {
            case .changed(let preferredChange):
                if let resolved = Self.resolveDocument(
                    previous: previousDocument,
                    current: state.document,
                    preferredChange: preferredChange
                ) {
                    document = resolved
                } else {
                    state = previousState
                    return nil
                }
            case .noVisibleChange:
                continue
            case .needsReload:
                state = previousState
                return nil
            }
        }
        return document
    }

    private static func resolveDocument(
        previous: ReviewMonitorLogDocument,
        current: ReviewMonitorLogDocument,
        preferredChange: ReviewMonitorLogChange?
    ) -> ReviewMonitorLogDocument? {
        guard let preferredChange else {
            return nil
        }

        guard contentChanged(previous: previous, current: current) else {
            return nil
        }

        var resolved = current
        resolved.revision = previous.revision &+ 1

        switch preferredChange {
        case .append(let append)
            where isContiguousAppend(
                append,
                previousUTF16Length: previous.textUTF16Length,
                currentUTF16Length: current.textUTF16Length
            ):
            resolved.lastChange = .append(append)
        case .replace(let replacement)
            where isValidReplacement(
                replacement,
                previousUTF16Length: previous.textUTF16Length,
                currentUTF16Length: current.textUTF16Length
            ):
            resolved.lastChange = .replace(replacement)
        default:
            resolved.lastChange = .reload
        }
        return resolved
    }

    private static func contentChanged(
        previous: ReviewMonitorLogDocument,
        current: ReviewMonitorLogDocument
    ) -> Bool {
        if previous.textUTF16Length != current.textUTF16Length {
            return true
        }
        if previous.sourceTextUTF16Length != current.sourceTextUTF16Length {
            return true
        }
        if previous.blocks != current.blocks {
            return true
        }
        if previous.styleRuns != current.styleRuns {
            return true
        }
        if previous.decorations != current.decorations {
            return true
        }
        return previous.text != current.text || previous.sourceText != current.sourceText
    }

    private static func isContiguousAppend(
        _ append: ReviewMonitorLogAppend,
        previousUTF16Length: Int,
        currentUTF16Length: Int
    ) -> Bool {
        let appendEnd = previousUTF16Length + append.textUTF16Length
        return append.textUTF16Length > 0 &&
            currentUTF16Length == appendEnd &&
            append.range.location >= previousUTF16Length &&
            NSMaxRange(append.range) <= appendEnd
    }

    private static func isValidReplacement(
        _ replacement: ReviewMonitorLogReplacement,
        previousUTF16Length: Int,
        currentUTF16Length: Int
    ) -> Bool {
        let replacementEnd = replacement.range.location + replacement.textUTF16Length
        return replacement.textUTF16Length >= 0 &&
            NSMaxRange(replacement.range) <= previousUTF16Length &&
            currentUTF16Length == previousUTF16Length - replacement.range.length + replacement.textUTF16Length &&
            replacementEnd <= currentUTF16Length
    }

    private static func requiresBlockRerenderOnDelta(kind: ReviewLogEntry.Kind) -> Bool {
        switch kind {
        case .agentMessage, .plan, .todoList, .reasoning, .reasoningSummary, .rawReasoning:
            return true
        case .command, .commandOutput, .toolCall, .diagnostic, .error, .progress, .event, .contextCompaction:
            return false
        }
    }

    private static func suffix(in text: String, afterPrefix prefix: String) -> String? {
        guard text.hasPrefix(prefix) else {
            return nil
        }
        return String(text.dropFirst(prefix.count))
    }

    private static func blockID(for entry: ReviewLogEntry) -> ReviewMonitorLogBlockID {
        if let key = mergeKey(for: entry) {
            return ReviewMonitorLogBlockID("\(key.kind.rawValue):\(key.groupID)")
        }
        return ReviewMonitorLogBlockID(entry.id.uuidString)
    }

    private static func mergeKey(for entry: ReviewLogEntry) -> GroupKey? {
        guard let groupID = entry.groupID,
              groupID.isEmpty == false
        else {
            return nil
        }

        switch entry.kind {
        case .agentMessage, .command, .commandOutput, .plan, .reasoning, .reasoningSummary, .rawReasoning, .contextCompaction:
            return GroupKey(kind: entry.kind, groupID: groupID)
        case .todoList, .toolCall, .diagnostic, .error, .progress, .event:
            return nil
        }
    }

    private static func replacementOnlyKey(for entry: ReviewLogEntry) -> GroupKey? {
        guard entry.kind == .toolCall,
              let groupID = entry.groupID,
              groupID.isEmpty == false
        else {
            return nil
        }
        return GroupKey(kind: entry.kind, groupID: groupID)
    }

    private static func isVisible(kind: ReviewLogEntry.Kind, text: String) -> Bool {
        guard displayedKinds.contains(kind) else {
            return false
        }
        if kind == .diagnostic {
            return true
        }
        return text.isEmpty == false
    }

    private static func utf16Length(_ text: String) -> Int {
        (text as NSString).length
    }

    private static let displayedKinds: Set<ReviewLogEntry.Kind> = [
        .agentMessage,
        .command,
        .commandOutput,
        .plan,
        .todoList,
        .reasoning,
        .reasoningSummary,
        .rawReasoning,
        .toolCall,
        .diagnostic,
        .error,
        .progress,
        .event,
        .contextCompaction,
    ]
}
