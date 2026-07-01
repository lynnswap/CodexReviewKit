import Foundation

struct ReviewMonitorLogProjectedBlock: Equatable, Sendable {
    var id: ReviewMonitorLog.BlockID
    var kind: ReviewMonitorLog.Kind
    var groupID: String?
    var text: String
    var metadata: ReviewMonitorLog.Metadata?
}

struct ReviewMonitorLogDocumentProjection: Sendable {
    private var document = ReviewMonitorLog.Document()

    var currentDocument: ReviewMonitorLog.Document {
        document
    }

    mutating func reset() {
        document = ReviewMonitorLog.Document()
    }

    mutating func render(projectedBlocks: [ReviewMonitorLogProjectedBlock]) -> ReviewMonitorLog.Document {
        let previous = document
        var current = Self.makeDocument(from: projectedBlocks)

        guard Self.contentChanged(previous: previous, current: current) else {
            return document
        }

        current.revision = previous.revision &+ 1
        current.lastChange = Self.preferredChange(previous: previous, current: current)
        document = current
        return document
    }

    private static func makeDocument(
        from projectedBlocks: [ReviewMonitorLogProjectedBlock]
    ) -> ReviewMonitorLog.Document {
        var builder = DocumentBuilder()
        for projectedBlock in projectedBlocks {
            builder.append(projectedBlock)
        }
        return builder.document
    }

    private static func preferredChange(
        previous: ReviewMonitorLog.Document,
        current: ReviewMonitorLog.Document
    ) -> ReviewMonitorLog.Change {
        if let append = appendChange(previous: previous, current: current) {
            return .append(append)
        }
        if let replacement = replacementChange(previous: previous, current: current) {
            return .replace(replacement)
        }
        return .reload
    }

    private static func appendChange(
        previous: ReviewMonitorLog.Document,
        current: ReviewMonitorLog.Document
    ) -> ReviewMonitorLog.Append? {
        guard current.textUTF16Length > previous.textUTF16Length,
            current.text.hasPrefix(previous.text)
        else {
            return nil
        }

        let suffix = String(current.text.dropFirst(previous.text.count))
        let suffixLength = utf16Length(suffix)
        let suffixRange = NSRange(location: previous.textUTF16Length, length: suffixLength)
        let block = current.blocks.first {
            NSIntersectionRange($0.range, suffixRange).length > 0
        }
        guard
            existingPresentationUnchanged(
                previous: previous,
                current: current,
                suffixBlockID: block?.id
            )
        else {
            return nil
        }
        return .init(
            kind: block?.kind ?? .event,
            blockID: block?.id ?? ReviewMonitorLog.BlockID("logAppend"),
            range: suffixRange,
            text: suffix,
            textUTF16Length: suffixLength,
            animationSpans: current.blocks.flatMap { block in
                let intersection = NSIntersectionRange(block.range, suffixRange)
                guard intersection.length > 0 else {
                    return [] as [ReviewMonitorLog.AnimationSpan]
                }
                return ReviewMonitorLog.Append.animationSpans(
                    forKind: block.kind,
                    absoluteRange: intersection,
                    appendBaseLocation: previous.textUTF16Length
                )
            }
        )
    }

    private static func existingPresentationUnchanged(
        previous: ReviewMonitorLog.Document,
        current: ReviewMonitorLog.Document,
        suffixBlockID: ReviewMonitorLog.BlockID?
    ) -> Bool {
        var currentBlocksByID = [ReviewMonitorLog.BlockID: ReviewMonitorLog.Block]()
        for currentBlock in current.blocks {
            currentBlocksByID[currentBlock.id] = currentBlock
        }

        for previousBlock in previous.blocks {
            guard let currentBlock = currentBlocksByID[previousBlock.id] else {
                return false
            }
            if previousBlock.id == suffixBlockID {
                guard currentBlock.kind == previousBlock.kind,
                    currentBlock.groupID == previousBlock.groupID,
                    currentBlock.range.location == previousBlock.range.location,
                    currentBlock.sourceRange.location == previousBlock.sourceRange.location,
                    currentBlock.metadata == previousBlock.metadata,
                    currentBlock.range.length >= previousBlock.range.length,
                    currentBlock.sourceRange.length >= previousBlock.sourceRange.length
                else {
                    return false
                }
            } else if currentBlock != previousBlock {
                return false
            }
        }
        return true
    }

    private static func replacementChange(
        previous: ReviewMonitorLog.Document,
        current: ReviewMonitorLog.Document
    ) -> ReviewMonitorLog.Replacement? {
        for previousBlock in previous.blocks {
            guard let currentBlock = current.blocks.first(where: { $0.id == previousBlock.id }),
                currentBlock.range.location == previousBlock.range.location,
                NSMaxRange(currentBlock.range) <= current.textUTF16Length
            else {
                continue
            }

            let replacementText = (current.text as NSString).substring(with: currentBlock.range)
            let candidate = replacingText(
                in: previous.text,
                range: previousBlock.range,
                with: replacementText
            )
            guard candidate == current.text else {
                continue
            }
            return .init(
                kind: currentBlock.kind,
                blockID: currentBlock.id,
                range: previousBlock.range,
                text: replacementText,
                textUTF16Length: currentBlock.range.length
            )
        }
        return nil
    }

    private static func replacingText(
        in text: String,
        range: NSRange,
        with replacement: String
    ) -> String {
        let string = text as NSString
        let prefix = string.substring(with: NSRange(location: 0, length: range.location))
        let suffixLocation = NSMaxRange(range)
        let suffix = string.substring(
            with: NSRange(location: suffixLocation, length: string.length - suffixLocation)
        )
        return prefix + replacement + suffix
    }

    private static func contentChanged(
        previous: ReviewMonitorLog.Document,
        current: ReviewMonitorLog.Document
    ) -> Bool {
        previous.text != current.text || previous.sourceText != current.sourceText || previous.blocks != current.blocks
            || previous.styleRuns != current.styleRuns || previous.decorations != current.decorations
    }

    private static func utf16Length(_ text: String) -> Int {
        (text as NSString).length
    }

    private struct DocumentBuilder {
        private(set) var document = ReviewMonitorLog.Document()
        private var hasVisibleSections = false

        mutating func append(_ block: ReviewMonitorLogProjectedBlock) {
            guard Self.isVisible(kind: block.kind, text: block.text) else {
                return
            }

            let renderedText = ReviewMonitorLogStyler.renderedText(
                for: block.kind,
                source: block.text,
                blockID: block.id
            )
            let appended = appendedText(renderedText, after: document.text)
            let appendedSource = appendedText(block.text, after: document.sourceText)
            hasVisibleSections = true

            let previousLength = document.textUTF16Length
            let previousSourceLength = document.sourceTextUTF16Length
            let suffixLength = ReviewMonitorLogDocumentProjection.utf16Length(appended)
            let sourceSuffixLength = ReviewMonitorLogDocumentProjection.utf16Length(appendedSource)
            let blockLength = ReviewMonitorLogDocumentProjection.utf16Length(renderedText)
            let sourceBlockLength = ReviewMonitorLogDocumentProjection.utf16Length(block.text)
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
            let logBlock = ReviewMonitorLog.Block(
                id: block.id,
                kind: block.kind,
                groupID: block.groupID,
                range: blockRange,
                sourceRange: sourceBlockRange,
                metadata: block.metadata
            )
            document.blocks.append(logBlock)
            ReviewMonitorLogStyler.appendPresentation(for: logBlock, to: &document)
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

        private static func isVisible(kind: ReviewMonitorLog.Kind, text: String) -> Bool {
            if kind == .diagnostic {
                return true
            }
            return text.isEmpty == false
        }
    }
}
