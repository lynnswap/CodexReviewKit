import Foundation

public struct ParsedReviewResult: Codable, Sendable, Hashable {
    public enum State: String, Codable, Sendable, Hashable {
        case hasFindings
        case noFindings
        case unknown
    }

    public enum Source: String, Codable, Sendable, Hashable {
        case parsedFinalReviewText
        case unrecognizedFindingBlock
        case notAvailable
    }

    public struct Finding: Codable, Sendable, Hashable {
        public struct Location: Codable, Sendable, Hashable {
            public var path: String
            public var startLine: Int
            public var endLine: Int

            public init(path: String, startLine: Int, endLine: Int) {
                self.path = path
                self.startLine = startLine
                self.endLine = endLine
            }
        }

        public var title: String
        public var body: String
        public var priority: Int?
        public var location: Location?
        public var rawText: String

        public init(
            title: String,
            body: String,
            priority: Int? = nil,
            location: Location? = nil,
            rawText: String
        ) {
            self.title = title
            self.body = body
            self.priority = priority
            self.location = location
            self.rawText = rawText
        }
    }

    public static let currentParserVersion = 3

    public var state: State
    public var findingCount: Int?
    public var findings: [Finding]
    public var source: Source
    public var parserVersion: Int

    public init(
        state: State,
        findingCount: Int?,
        findings: [Finding],
        source: Source,
        parserVersion: Int = Self.currentParserVersion
    ) {
        self.state = state
        self.findingCount = findingCount
        self.findings = findings
        self.source = source
        self.parserVersion = parserVersion
    }

    public static func notAvailable() -> ParsedReviewResult {
        ParsedReviewResult(
            state: .unknown,
            findingCount: nil,
            findings: [],
            source: .notAvailable
        )
    }

    public static func parse(finalReviewText text: String?) -> ParsedReviewResult {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              text.isEmpty == false
        else {
            return notAvailable()
        }

        let lines = text.components(separatedBy: .newlines)
        let legacyHeaderIndex = lines.indices.first {
            isLegacyFindingHeader(in: lines, at: $0)
        }
        let currentFindingLines = lines.indices.filter {
            isCurrentFindingCandidate(in: lines, at: $0)
        }
        if let headerIndex = legacyHeaderIndex,
           currentFindingLines.first.map({ headerIndex < $0 }) != false
        {
            return parseLegacyFindings(in: lines.dropFirst(headerIndex + 1))
        }

        if currentFindingLines.isEmpty == false {
            return parseCurrentFindings(in: lines, at: currentFindingLines)
        }

        if isExplicitNoFindings(lines) {
            return ParsedReviewResult(
                state: .noFindings,
                findingCount: 0,
                findings: [],
                source: .parsedFinalReviewText
            )
        }

        return unrecognizedResult()
    }

    private static func parseLegacyFindings(
        in lines: ArraySlice<String>
    ) -> ParsedReviewResult {
        var findings: [ParsedReviewResult.Finding] = []
        var current: FindingBuilder?
        var malformed = false

        for line in lines {
            if let finding = parseFindingLine(
                line,
                requiresBullet: true,
                requiresPriority: false
            ) {
                if let built = current?.build() {
                    findings.append(built)
                }
                current = FindingBuilder(
                    findingLine: line,
                    finding: finding,
                    bodyStyle: .indented
                )
                continue
            }

            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }

            guard line.hasPrefix("  "), current != nil else {
                malformed = true
                continue
            }

            current?.appendBodyLine(String(line.dropFirst(2)))
        }

        if let built = current?.build() {
            findings.append(built)
        }

        guard malformed == false, findings.isEmpty == false else {
            return unrecognizedResult()
        }

        return findingsResult(findings)
    }

    private static func parseCurrentFindings(
        in lines: [String],
        at findingLineIndices: [Int]
    ) -> ParsedReviewResult {
        let parsedLines = findingLineIndices.map { index in
            (
                index: index,
                line: lines[index],
                finding: parseFindingLine(
                    lines[index],
                    requiresBullet: false,
                    requiresPriority: true
                )
            )
        }
        guard parsedLines.allSatisfy({ $0.finding != nil }) else {
            return unrecognizedResult()
        }

        var findings: [ParsedReviewResult.Finding] = []
        for (offset, parsedLine) in parsedLines.enumerated() {
            guard let finding = parsedLine.finding else {
                return unrecognizedResult()
            }
            let endIndex = parsedLines.dropFirst(offset + 1).first?.index ?? lines.endIndex
            var builder = FindingBuilder(
                findingLine: parsedLine.line.trimmingCharacters(in: .whitespaces),
                finding: finding,
                bodyStyle: .plain
            )
            for line in currentFindingBodyParagraph(
                lines[(parsedLine.index + 1)..<endIndex]
            ) {
                builder.appendBodyLine(line)
            }
            findings.append(builder.build())
        }

        return findingsResult(findings)
    }

    private static func currentFindingBodyParagraph(
        _ lines: ArraySlice<String>
    ) -> [String] {
        var bodyLines: [String] = []
        var started = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                if started {
                    break
                }
                continue
            }
            started = true
            bodyLines.append(trimmed)
        }
        return bodyLines
    }

    private static func findingsResult(
        _ findings: [ParsedReviewResult.Finding]
    ) -> ParsedReviewResult {
        return ParsedReviewResult(
            state: .hasFindings,
            findingCount: findings.count,
            findings: findings,
            source: .parsedFinalReviewText
        )
    }

    private static func isFindingHeader(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == "Review comment:" || trimmed == "Full review comments:"
    }

    private static func isLegacyFindingHeader(
        in lines: [String],
        at index: Int
    ) -> Bool {
        guard isFindingHeader(lines[index]) else {
            return false
        }
        return lines[(index + 1)...].first { line in
            line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }.flatMap {
            parseFindingLine($0, requiresBullet: true, requiresPriority: false)
        } != nil
    }

    private static func isExplicitNoFindings(_ lines: [String]) -> Bool {
        guard let firstLine = lines.lazy
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { $0.isEmpty == false })
        else {
            return false
        }
        return [
            "No findings.",
            "No findings",
            "No correctness issues found.",
            "No correctness issues found in the touched files.",
        ].contains(firstLine)
    }

    private static func isCurrentFindingCandidate(
        in lines: [String],
        at index: Int
    ) -> Bool {
        guard lines[index].first?.isWhitespace != true else {
            return false
        }
        if index > lines.startIndex,
           lines[index - 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        {
            return false
        }
        let line = lines[index]
        let content = line.hasPrefix("- ") ? String(line.dropFirst(2)) : line
        return parsePriority(content) != nil
    }

    private static func parseFindingLine(
        _ line: String,
        requiresBullet: Bool,
        requiresPriority: Bool
    ) -> ParsedFindingLine? {
        let content: String
        if requiresBullet {
            guard line.hasPrefix("- ") else {
                return nil
            }
            content = String(line.dropFirst(2))
        } else {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            content = trimmed.hasPrefix("- ") ? String(trimmed.dropFirst(2)) : trimmed
        }
        let delimiter = " \u{2014} "
        guard let delimiterRange = content.range(of: delimiter, options: .backwards) else {
            return nil
        }

        let title = String(content[..<delimiterRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let locationText = String(content[delimiterRange.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let priority = parsePriority(title)
        guard title.isEmpty == false,
              requiresPriority == false || priority != nil,
              let location = parseLocation(locationText)
        else {
            return nil
        }

        return ParsedFindingLine(
            title: title,
            priority: priority,
            location: location
        )
    }

    private static func parseLocation(_ text: String) -> ParsedReviewResult.Finding.Location? {
        guard let text = locationText(from: text),
              let colonIndex = text.lastIndex(of: ":")
        else {
            return nil
        }
        let path = String(text[..<colonIndex])
        let rangeText = String(text[text.index(after: colonIndex)...])
        let parts = rangeText.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let startText = parts.first,
              let startLine = Int(startText),
              let endLine = parts.count == 1 ? startLine : Int(parts[1]),
              path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              startLine > 0,
              endLine >= startLine
        else {
            return nil
        }

        return ParsedReviewResult.Finding.Location(
            path: path.trimmingCharacters(in: .whitespacesAndNewlines),
            startLine: startLine,
            endLine: endLine
        )
    }

    private static func locationText(from text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let startsWithBacktick = text.first == "`"
        let endsWithBacktick = text.last == "`"
        switch (startsWithBacktick, endsWithBacktick) {
        case (false, false):
            return text.contains("`") ? nil : text
        case (true, true):
            let content = text.dropFirst().dropLast()
            guard content.isEmpty == false, content.contains("`") == false else {
                return nil
            }
            return String(content)
        case (true, false), (false, true):
            return nil
        }
    }

    private static func parsePriority(_ title: String) -> Int? {
        guard title.count >= 4,
              title.first == "[",
              title[title.index(after: title.startIndex)] == "P",
              title[title.index(title.startIndex, offsetBy: 3)] == "]"
        else {
            return nil
        }

        let digitIndex = title.index(title.startIndex, offsetBy: 2)
        guard let priority = Int(String(title[digitIndex])),
              (0...3).contains(priority)
        else {
            return nil
        }
        return priority
    }

    private static func unrecognizedResult() -> ParsedReviewResult {
        ParsedReviewResult(
            state: .unknown,
            findingCount: nil,
            findings: [],
            source: .unrecognizedFindingBlock
        )
    }
}

private struct ParsedFindingLine {
    var title: String
    var priority: Int?
    var location: ParsedReviewResult.Finding.Location
}

private struct FindingBuilder {
    enum BodyStyle {
        case indented
        case plain
    }

    var findingLine: String
    var finding: ParsedFindingLine
    var bodyStyle: BodyStyle
    var bodyLines: [String] = []

    mutating func appendBodyLine(_ line: String) {
        bodyLines.append(line)
    }

    func build() -> ParsedReviewResult.Finding {
        let body = bodyLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rawLines = [findingLine] + bodyLines.map { line in
            switch bodyStyle {
            case .indented: "  \(line)"
            case .plain: line
            }
        }
        return ParsedReviewResult.Finding(
            title: finding.title,
            body: body,
            priority: finding.priority,
            location: finding.location,
            rawText: rawLines.joined(separator: "\n")
        )
    }
}
