import Foundation

enum ReviewMonitorLogLineCounter {
    struct Metrics: Equatable, Sendable {
        var lineCount: Int
        var maximumLineUTF16Length: Int
    }

    static func lineCount(_ text: String) -> Int {
        metrics(text).lineCount
    }

    static func metrics(_ text: String) -> Metrics {
        let string = text as NSString
        return metrics(in: string, range: NSRange(location: 0, length: string.length))
    }

    static func lineCount(in string: NSString, range requestedRange: NSRange) -> Int {
        metrics(in: string, range: requestedRange).lineCount
    }

    static func metrics(in string: NSString, range requestedRange: NSRange) -> Metrics {
        let stringRange = NSRange(location: 0, length: string.length)
        let range = NSIntersectionRange(requestedRange, stringRange)
        guard range.length > 0 else {
            return Metrics(lineCount: 0, maximumLineUTF16Length: 0)
        }

        var count = 1
        var currentLineLength = 0
        var maximumLineLength = 0
        let end = NSMaxRange(range)
        var index = range.location
        while index < end {
            if string.character(at: index) == 10 {
                maximumLineLength = max(maximumLineLength, currentLineLength)
                count += 1
                currentLineLength = 0
            } else {
                currentLineLength += 1
            }
            index += 1
        }
        if string.character(at: end - 1) == 10 {
            count -= 1
        } else {
            maximumLineLength = max(maximumLineLength, currentLineLength)
        }
        return Metrics(lineCount: max(0, count), maximumLineUTF16Length: maximumLineLength)
    }
}
