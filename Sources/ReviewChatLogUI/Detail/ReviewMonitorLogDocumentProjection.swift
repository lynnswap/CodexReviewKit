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
        guard let candidate = replacementCandidate(previous: previous, current: current) else {
            return nil
        }

        guard rangeIsValid(candidate.previous.range, upperBound: previous.textUTF16Length),
            rangeIsValid(candidate.current.range, upperBound: current.textUTF16Length),
            rangeIsValid(candidate.previous.sourceRange, upperBound: previous.sourceTextUTF16Length),
            rangeIsValid(candidate.current.sourceRange, upperBound: current.sourceTextUTF16Length)
        else {
            return nil
        }

        let replacementText = (current.text as NSString).substring(with: candidate.current.range)
        let replacementSource = (current.sourceText as NSString).substring(with: candidate.current.sourceRange)
        guard ReviewMonitorUTF16TextReplacement.replacing(
            previous.text,
            range: candidate.previous.range,
            with: replacementText,
            equals: current.text
        ),
            ReviewMonitorUTF16TextReplacement.replacing(
                previous.sourceText,
                range: candidate.previous.sourceRange,
                with: replacementSource,
                equals: current.sourceText
            )
        else {
            return nil
        }

        return .init(
            kind: candidate.current.kind,
            blockID: candidate.current.id,
            range: candidate.previous.range,
            text: replacementText,
            textUTF16Length: candidate.current.range.length
        )
    }

    private static func replacementCandidate(
        previous: ReviewMonitorLog.Document,
        current: ReviewMonitorLog.Document
    ) -> (previous: ReviewMonitorLog.Block, current: ReviewMonitorLog.Block)? {
        guard previous.blocks.count == current.blocks.count else {
            return nil
        }

        var candidate: (previous: ReviewMonitorLog.Block, current: ReviewMonitorLog.Block)?
        var displayDelta = 0
        var sourceDelta = 0
        for index in previous.blocks.indices {
            let previousBlock = previous.blocks[index]
            let currentBlock = current.blocks[index]
            if candidate != nil {
                guard unchangedBlockAfterReplacement(
                    previous: previousBlock,
                    current: currentBlock,
                    displayDelta: displayDelta,
                    sourceDelta: sourceDelta,
                    previousDocument: previous,
                    currentDocument: current
                ) else {
                    return nil
                }
                continue
            }

            if blockContentUnchanged(
                previous: previousBlock,
                current: currentBlock,
                previousDocument: previous,
                currentDocument: current
            ) {
                continue
            }
            guard canReplaceSingleBlock(previous: previousBlock, current: currentBlock) else {
                return nil
            }
            candidate = (previous: previousBlock, current: currentBlock)
            displayDelta = currentBlock.range.length - previousBlock.range.length
            sourceDelta = currentBlock.sourceRange.length - previousBlock.sourceRange.length
        }
        return candidate
    }

    private static func canReplaceSingleBlock(
        previous: ReviewMonitorLog.Block,
        current: ReviewMonitorLog.Block
    ) -> Bool {
        previous.id == current.id
            && previous.kind == current.kind
            && previous.groupID == current.groupID
            && current.range.location == previous.range.location
            && current.sourceRange.location == previous.sourceRange.location
            && rangeIsValid(previous.range)
            && rangeIsValid(current.range)
            && rangeIsValid(previous.sourceRange)
            && rangeIsValid(current.sourceRange)
    }

    private static func unchangedBlockAfterReplacement(
        previous: ReviewMonitorLog.Block,
        current: ReviewMonitorLog.Block,
        displayDelta: Int,
        sourceDelta: Int,
        previousDocument: ReviewMonitorLog.Document,
        currentDocument: ReviewMonitorLog.Document
    ) -> Bool {
        guard previous.id == current.id
            && previous.kind == current.kind
            && previous.groupID == current.groupID
            && previous.metadata == current.metadata
            && current.range.location == previous.range.location + displayDelta
            && current.range.length == previous.range.length
            && current.sourceRange.location == previous.sourceRange.location + sourceDelta
            && current.sourceRange.length == previous.sourceRange.length
        else {
            return false
        }
        return blockContentUnchanged(
            previous: previous,
            current: current,
            previousDocument: previousDocument,
            currentDocument: currentDocument
        )
    }

    private static func blockContentUnchanged(
        previous: ReviewMonitorLog.Block,
        current: ReviewMonitorLog.Block,
        previousDocument: ReviewMonitorLog.Document,
        currentDocument: ReviewMonitorLog.Document
    ) -> Bool {
        guard previous.id == current.id,
            previous.kind == current.kind,
            previous.groupID == current.groupID,
            previous.metadata == current.metadata,
            rangeIsValid(previous.range, upperBound: previousDocument.textUTF16Length),
            rangeIsValid(current.range, upperBound: currentDocument.textUTF16Length),
            rangeIsValid(previous.sourceRange, upperBound: previousDocument.sourceTextUTF16Length),
            rangeIsValid(current.sourceRange, upperBound: currentDocument.sourceTextUTF16Length),
            ReviewMonitorUTF16TextReplacement.segmentsEqual(
                previousDocument.text,
                range: previous.range,
                currentDocument.text,
                range: current.range
            ),
            ReviewMonitorUTF16TextReplacement.segmentsEqual(
                previousDocument.sourceText,
                range: previous.sourceRange,
                currentDocument.sourceText,
                range: current.sourceRange
            )
        else {
            return false
        }
        return true
    }

    private static func rangeIsValid(_ range: NSRange) -> Bool {
        range.location >= 0 && range.length >= 0
    }

    private static func rangeIsValid(_ range: NSRange, upperBound: Int) -> Bool {
        range.location >= 0 && range.length >= 0 && NSMaxRange(range) <= upperBound
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

            // Block text must not carry the inter-block separator: command
            // panels replace their block text with a placeholder, so a
            // separator living inside a neighboring block's trailing newlines
            // would silently disappear from the display document.
            let sourceText = Self.normalizedBlockText(block.text)
            let renderedText = Self.normalizedBlockText(
                ReviewMonitorLogStyler.renderedText(
                    for: block.kind,
                    source: sourceText,
                    blockID: block.id
                ))
            let appended = appendedText(renderedText, after: document.text)
            let appendedSource = appendedText(sourceText, after: document.sourceText)
            hasVisibleSections = true

            let previousLength = document.textUTF16Length
            let previousSourceLength = document.sourceTextUTF16Length
            let suffixLength = ReviewMonitorLogDocumentProjection.utf16Length(appended)
            let sourceSuffixLength = ReviewMonitorLogDocumentProjection.utf16Length(appendedSource)
            let blockLength = ReviewMonitorLogDocumentProjection.utf16Length(renderedText)
            let sourceBlockLength = ReviewMonitorLogDocumentProjection.utf16Length(sourceText)
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
            return "\n\n" + blockText
        }

        private static func normalizedBlockText(_ text: String) -> String {
            text.trimmingCharacters(in: .newlines)
        }

        private static func isVisible(kind: ReviewMonitorLog.Kind, text: String) -> Bool {
            if kind == .diagnostic {
                return true
            }
            return text.isEmpty == false
        }
    }
}
