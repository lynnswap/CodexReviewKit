import Foundation

public protocol ReviewStringIdentifier: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral where RawValue == String {
    init(rawValue: String)
}

public extension ReviewStringIdentifier {
    init(stringLiteral value: String) {
        self.init(rawValue: value)
    }
}

public struct ReviewThreadID: ReviewStringIdentifier, CustomStringConvertible {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String {
        rawValue
    }
}

public struct ReviewTurnID: ReviewStringIdentifier, CustomStringConvertible {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String {
        rawValue
    }
}

package struct ReviewEventItemID: ReviewStringIdentifier, CustomStringConvertible {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String {
        rawValue
    }
}

public struct ReviewToolCallID: ReviewStringIdentifier, CustomStringConvertible {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String {
        rawValue
    }
}

public enum ReviewThread {
    public typealias ID = ReviewThreadID
}

public enum ReviewTurn {
    public typealias ID = ReviewTurnID
}

public enum ReviewToolCall {
    public typealias ID = ReviewToolCallID
}
