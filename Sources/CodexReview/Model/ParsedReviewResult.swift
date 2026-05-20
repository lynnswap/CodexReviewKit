import Foundation

public enum ParsedReviewResultState: String, Codable, Sendable, Hashable {
    case hasFindings
    case noFindings
    case unknown
}

public enum ParsedReviewResultSource: String, Codable, Sendable, Hashable {
    case parsedFinalReviewText
    case unrecognizedFindingBlock
    case notAvailable
}

public struct ParsedReviewFindingLocation: Codable, Sendable, Hashable {
    public var path: String
    public var startLine: Int
    public var endLine: Int

    public init(path: String, startLine: Int, endLine: Int) {
        self.path = path
        self.startLine = startLine
        self.endLine = endLine
    }
}

public struct ParsedReviewFinding: Codable, Sendable, Hashable {
    public var title: String
    public var body: String
    public var priority: Int?
    public var location: ParsedReviewFindingLocation?
    public var rawText: String

    public init(
        title: String,
        body: String,
        priority: Int? = nil,
        location: ParsedReviewFindingLocation? = nil,
        rawText: String
    ) {
        self.title = title
        self.body = body
        self.priority = priority
        self.location = location
        self.rawText = rawText
    }
}

public struct ParsedReviewResult: Codable, Sendable, Hashable {
    public static let currentParserVersion = 1

    public var state: ParsedReviewResultState
    public var findingCount: Int?
    public var findings: [ParsedReviewFinding]
    public var source: ParsedReviewResultSource
    public var parserVersion: Int

    public init(
        state: ParsedReviewResultState,
        findingCount: Int?,
        findings: [ParsedReviewFinding],
        source: ParsedReviewResultSource,
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
        guard let headerIndex = lines.firstIndex(where: isFindingHeader) else {
            return ParsedReviewResult(
                state: .noFindings,
                findingCount: 0,
                findings: [],
                source: .parsedFinalReviewText
            )
        }

        var findings: [ParsedReviewFinding] = []
        var current: FindingBuilder?
        var malformed = false

        for line in lines.dropFirst(headerIndex + 1) {
            if let finding = parseFindingLine(line) {
                if let built = current?.build() {
                    findings.append(built)
                }
                current = FindingBuilder(findingLine: line, finding: finding)
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
            return ParsedReviewResult(
                state: .unknown,
                findingCount: nil,
                findings: [],
                source: .unrecognizedFindingBlock
            )
        }

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

    private static func parseFindingLine(_ line: String) -> ParsedFindingLine? {
        guard line.hasPrefix("- ") else {
            return nil
        }

        let content = String(line.dropFirst(2))
        let delimiter = " \u{2014} "
        guard let delimiterRange = content.range(of: delimiter, options: .backwards) else {
            return nil
        }

        let title = String(content[..<delimiterRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let locationText = String(content[delimiterRange.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.isEmpty == false,
              let location = parseLocation(locationText)
        else {
            return nil
        }

        return ParsedFindingLine(
            title: title,
            priority: parsePriority(title),
            location: location
        )
    }

    private static func parseLocation(_ text: String) -> ParsedReviewFindingLocation? {
        guard let colonIndex = text.lastIndex(of: ":") else {
            return nil
        }
        let path = String(text[..<colonIndex])
        let rangeText = String(text[text.index(after: colonIndex)...])
        let parts = rangeText.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let startLine = Int(parts[0]),
              let endLine = Int(parts[1]),
              path.isEmpty == false,
              startLine > 0,
              endLine >= startLine
        else {
            return nil
        }

        return ParsedReviewFindingLocation(
            path: path,
            startLine: startLine,
            endLine: endLine
        )
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
}

private struct ParsedFindingLine {
    var title: String
    var priority: Int?
    var location: ParsedReviewFindingLocation
}

private struct FindingBuilder {
    var findingLine: String
    var finding: ParsedFindingLine
    var bodyLines: [String] = []

    mutating func appendBodyLine(_ line: String) {
        bodyLines.append(line)
    }

    func build() -> ParsedReviewFinding {
        let body = bodyLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rawLines = [findingLine] + bodyLines.map { "  \($0)" }
        return ParsedReviewFinding(
            title: finding.title,
            body: body,
            priority: finding.priority,
            location: finding.location,
            rawText: rawLines.joined(separator: "\n")
        )
    }
}
