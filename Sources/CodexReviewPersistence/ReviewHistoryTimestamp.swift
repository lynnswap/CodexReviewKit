import Foundation

enum ReviewHistoryTimestamp {
    static func encode(_ date: Date) -> Double {
        date.timeIntervalSinceReferenceDate
    }

    static func decode(_ value: Double) -> Date {
        Date(timeIntervalSinceReferenceDate: value)
    }
}
