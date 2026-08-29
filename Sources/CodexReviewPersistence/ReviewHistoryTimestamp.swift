import Foundation

enum ReviewHistoryTimestamp {
    static func normalize(_ date: Date) throws -> Date {
        let format = Date.ISO8601FormatStyle()
            .year()
            .month()
            .day()
            .dateTimeSeparator(.space)
            .time(includingFractionalSeconds: true)
        return try Date(date.formatted(format), strategy: format)
    }
}
